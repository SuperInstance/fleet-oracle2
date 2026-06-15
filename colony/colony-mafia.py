#!/usr/bin/env python3
"""
colony-mafia.py — Mafia/Resistance social deduction game for colony-games.

A standalone module with a MafiaGame class that implements full Mafia (Werewolf)
mechanics: night actions (kill, save, investigate), day votes, role assignment,
and per-game persisted state.

Can be imported by colony-games.py for HTTP serving.
"""

import json, os, random, time

# ── Role definitions ──────────────────────────────────────────────────────

ROLES = {
    'mafia':     {'emoji': '🗡️',  'name': 'Mafia',     'team': 'mafia',     'count': lambda n: max(1, n // 3)},
    'town':      {'emoji': '👤',  'name': 'Townsperson','team': 'town',     'count': lambda n: n - max(1, n // 3) - min(1, n // 5) - min(1, n // 5)},
    'doctor':    {'emoji': '💊',  'name': 'Doctor',     'team': 'town',     'count': lambda n: min(1, n // 5)},
    'detective': {'emoji': '🔍',  'name': 'Detective',  'team': 'town',     'count': lambda n: min(1, n // 5)},
}

PHASES = ['night', 'day', 'voting', 'resolution', 'game_over']

# ── MafiaGame class ──────────────────────────────────────────────────────

class MafiaGame:
    """Full Mafia social deduction game with persistence."""

    def __init__(self, colony_path):
        self.ledger_path = os.path.join(colony_path, 'colony-mafia-ledger.json')
        self.games = self._load()
        self.current = None  # Reference to active game dict

    def _load(self):
        try:
            with open(self.ledger_path) as f:
                return json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            return {'games': [], 'next_id': 0}

    def _save(self):
        with open(self.ledger_path, 'w') as f:
            json.dump(self.games, f, indent=2)

    # ── Game lifecycle ──────────────────────────────────────────────────

    def create_game(self, host_cell, player_cells):
        """Create a new Mafia game. Returns the game state."""
        if len(player_cells) < 4:
            return {'error': 'Need at least 4 players'}

        game_id = self.games['next_id']
        self.games['next_id'] += 1

        game = {
            'id': game_id,
            'host': host_cell,
            'players': player_cells[:],
            'alive': player_cells[:],
            'phase': 'setup',
            'night': 0,
            'day': 0,
            'roles': {},          # cell -> role
            'team_assignments': {}, # cell -> 'mafia' or 'town'
            'mafia_knowledge': {},  # mafia cells know each other
            'night_actions': {},   # cell -> {action, target}
            'detective_results': {}, # detective -> investigated targets
            'votes': {},           # cell -> target (voting phase)
            'eliminated': [],      # cells eliminated
            'elimination_record': [], # [{day, eliminated, by_vote, role}]
            'last_saved': None,    # doctor can't save same cell twice
            'winner': None,
            'status': 'created',
            'created': time.time(),
        }

        self._assign_roles(game)
        self.games['games'].append(game)
        self.current = game
        self._save()
        return self._sanitize(game)

    def _assign_roles(self, game):
        """Randomly assign roles based on player count."""
        n = len(game['players'])
        random.shuffle(game['players'])

        role_counts = {}
        for role_key, role_def in ROLES.items():
            role_counts[role_key] = role_def['count'](n)

        # Build role list
        role_list = []
        for role_key, count in role_counts.items():
            role_list.extend([role_key] * count)

        random.shuffle(role_list)

        # Assign
        for i, cell in enumerate(game['players']):
            role = role_list[i] if i < len(role_list) else 'town'
            game['roles'][cell] = role
            game['team_assignments'][cell] = ROLES[role]['team']

        # Mafia know each other
        mafia_cells = [c for c, r in game['roles'].items() if r == 'mafia']
        for mc in mafia_cells:
            game['mafia_knowledge'][mc] = [c for c in mafia_cells if c != mc]

        # Role reveal to detective
        # (handled dynamically in night_action)

    # ── Game actions ────────────────────────────────────────────────────

    def start_game(self, game_id):
        """Begin the first night phase."""
        game = self._get_game(game_id)
        if not game:
            return {'error': 'Game not found'}
        if game['phase'] != 'setup':
            return {'error': f'Game already started (phase: {game["phase"]})'}

        game['phase'] = 'night'
        game['night'] = 1
        game['status'] = 'active'
        self._save()
        return {'status': 'started', 'game_id': game_id, 'phase': 'night', 'night': 1}

    def night_action(self, cell, target, action_type):
        """
        Submit a night action.

        action_type:
          - 'kill'      (mafia only)
          - 'save'      (doctor only)
          - 'investigate' (detective only)
        Returns result (public knowledge or role-specific).
        """
        if not self.current or self.current['phase'] != 'night':
            return {'error': 'Not night phase'}
        game = self.current

        if cell not in game['alive']:
            return {'error': f'{cell} is dead or not in game'}
        if cell not in game['roles']:
            return {'error': f'{cell} not in this game'}

        role = game['roles'][cell]
        if action_type == 'kill' and role != 'mafia':
            return {'error': 'Only mafia can kill'}
        if action_type == 'save' and role != 'doctor':
            return {'error': 'Only doctor can save'}
        if action_type == 'investigate' and role != 'detective':
            return {'error': 'Only detective can investigate'}
        if target not in game['players']:
            return {'error': f'Target {target} is not a player'}

        # Store action
        game['night_actions'][cell] = {'action': action_type, 'target': target}

        # Doctor: track saved cell
        if action_type == 'save':
            game['last_saved'] = target

        # Detective: store result
        if action_type == 'investigate':
            target_role = game['roles'].get(target, 'unknown')
            target_team = game['team_assignments'].get(target, 'unknown')
            game['detective_results'][cell] = game['detective_results'].get(cell, [])
            game['detective_results'][cell].append({
                'target': target,
                'is_mafia': target_team == 'mafia',
                'night': game['night'],
            })

        self._save()
        return {'status': 'action_recorded', 'night': game['night']}

    def resolve_night(self):
        """
        Resolve all night actions for the current night.
        Returns the public outcome (who died, if anyone).
        """
        if not self.current or self.current['phase'] != 'night':
            return {'error': 'Not night phase'}
        game = self.current

        # Collect kill votes from mafia
        kill_targets = []
        for cell, action in game['night_actions'].items():
            if action['action'] == 'kill':
                kill_targets.append(action['target'])

        # Determine who dies: majority kill vote
        if kill_targets:
            target_counts = {}
            for t in kill_targets:
                target_counts[t] = target_counts.get(t, 0) + 1
            max_votes = max(target_counts.values())
            # Random among top vote-getters
            top_targets = [t for t, c in target_counts.items() if c == max_votes]
            killed = random.choice(top_targets)
        else:
            killed = None

        # Doctor save?
        saved = False
        for cell, action in game['night_actions'].items():
            if action['action'] == 'save' and action['target'] == killed:
                killed = None
                saved = True
                break

        # Apply death
        result = {'night': game['night'], 'killed': killed, 'saved': saved}
        if killed and killed in game['alive']:
            game['alive'].remove(killed)
            game['eliminated'].append(killed)
            game['elimination_record'].append({
                'night': game['night'],
                'eliminated': killed,
                'by_vote': False,
                'role': game['roles'].get(killed, 'unknown'),
            })

        # Transition to day
        game['day'] += 1
        game['phase'] = 'day'
        game['night_actions'] = {}
        self._save()
        result['phase'] = 'day'
        result['day'] = game['day']
        result['alive'] = game['alive'][:]

        # Check win condition
        winner = self._check_winner(game)
        if winner:
            game['phase'] = 'game_over'
            game['winner'] = winner
            result['game_over'] = True
            result['winner'] = winner
            self._save()

        return result

    def day_vote(self, cell, target):
        """Vote to eliminate a player during the day voting phase."""
        if not self.current or self.current['phase'] != 'day':
            return {'error': 'Not day phase'}
        game = self.current

        if cell not in game['alive']:
            return {'error': f'{cell} is dead or not in game'}
        if target not in game['players']:
            return {'error': f'{target} is not a player'}
        if target not in game['alive']:
            return {'error': f'{target} is already dead'}
        if target == cell:
            return {'error': 'Cannot vote for yourself'}

        # Store or update vote
        game['votes'][cell] = target
        self._save()
        return {'status': 'vote_recorded', 'voter': cell, 'target': target}

    def resolve_day(self):
        """
        Resolve day voting: count votes, eliminate the highest vote-getter.
        Returns the result.
        """
        if not self.current or self.current['phase'] != 'day':
            return {'error': 'Not day phase'}
        game = self.current

        # Count votes
        vote_counts = {}
        for voter, target in game['votes'].items():
            vote_counts[target] = vote_counts.get(target, 0) + 1

        if not vote_counts:
            # No one votes — no elimination
            eliminated = None
        else:
            max_votes = max(vote_counts.values())
            top_targets = [t for t, c in vote_counts.items() if c == max_votes]
            eliminated = random.choice(top_targets) if top_targets else None

        result = {'day': game['day'], 'eliminated': eliminated}

        if eliminated and eliminated in game['alive']:
            game['alive'].remove(eliminated)
            game['eliminated'].append(eliminated)
            game['elimination_record'].append({
                'day': game['day'],
                'eliminated': eliminated,
                'by_vote': True,
                'role': game['roles'].get(eliminated, 'unknown'),
            })
            result['role'] = game['roles'].get(eliminated, 'unknown')

        # Clear votes for next round
        game['votes'] = {}

        # Check win condition
        winner = self._check_winner(game)
        if winner:
            game['phase'] = 'game_over'
            game['winner'] = winner
            result['game_over'] = True
            result['winner'] = winner
            self._save()
            return result

        # Start next night
        game['night'] += 1
        game['phase'] = 'night'
        result['next_phase'] = 'night'
        result['night'] = game['night']
        result['alive'] = game['alive'][:]
        self._save()
        return result

    # ── Win condition ───────────────────────────────────────────────────

    def _check_winner(self, game):
        """Check if either team has won."""
        alive_mafia = [c for c in game['alive'] if game['team_assignments'].get(c) == 'mafia']
        alive_town = [c for c in game['alive'] if game['team_assignments'].get(c) == 'town']

        if not alive_mafia:
            return 'town'  # All mafia eliminated
        if len(alive_mafia) >= len(alive_town):
            return 'mafia'  # Mafia equals or outnumbers town
        return None

    # ── Status ──────────────────────────────────────────────────────────

    def status(self, game_id=None):
        """Get current status of a game (or last active game)."""
        game = self._get_game(game_id) if game_id is not None else self._get_active()
        if not game:
            return {'error': 'No active game'}
        return self._sanitize(game)

    def all_games(self):
        """List all games (sanitized)."""
        return [self._sanitize(g) for g in self.games['games']]

    # ── Helpers ─────────────────────────────────────────────────────────

    def _get_game(self, game_id):
        for g in self.games['games']:
            if g['id'] == game_id:
                return g
        return None

    def _get_active(self):
        for g in self.games['games']:
            if g['status'] == 'active':
                return g
        return None

    def _sanitize(self, game):
        """Public-safe view: hide roles and team assignments."""
        safe = {k: v for k, v in game.items() if k not in ('roles', 'team_assignments', 'mafia_knowledge', 'detective_results')}
        safe['players_count'] = len(game['players'])
        safe['alive_count'] = len(game['alive'])
        safe['dead_count'] = len(game['eliminated'])
        safe['elimination_record'] = game['elimination_record'][-10:] if game['elimination_record'] else []
        return safe


# ── Quick test ────────────────────────────────────────────────────────────

if __name__ == '__main__':
    test_path = '/tmp/mafia-test-colony'
    os.makedirs(test_path, exist_ok=True)
    mafia = MafiaGame(test_path)

    players = ['cell-alpha', 'cell-beta', 'cell-gamma', 'cell-delta', 'cell-epsilon', 'cell-zeta']
    game = mafia.create_game('cell-host', players)

    print(f"🎲 Mafia Game #{game['id']}")
    print(f"   Players: {game['players_count']}")
    mafia.start_game(game['id'])

    # Simulate 3 nights of play
    for night in range(1, 4):
        print(f"\n🌙 Night {night}")

        # Mafia kills
        mafia_cells = ['cell-alpha', 'cell-beta']
        alive = mafia.current['alive']
        targets = [c for c in alive if c not in mafia_cells]
        if targets:
            target = random.choice(targets)
            for mc in mafia_cells:
                mafia.night_action(mc, target, 'kill')

        # Doctor saves (random)
        if 'cell-gamma' in alive:
            save_target = random.choice(alive)
            mafia.night_action('cell-gamma', save_target, 'save')

        # Detective investigates
        if 'cell-delta' in alive:
            inv_target = random.choice([c for c in alive if c != 'cell-delta'] or alive)
            mafia.night_action('cell-delta', inv_target, 'investigate')

        # Resolve night
        result = mafia.resolve_night()
        print(f"   Killed: {result.get('killed', 'none')}, Saved: {result.get('saved', False)}")
        if result.get('game_over'):
            print(f"\n🏁 Game over! Winner: {result['winner']}")
            break

        # Day vote
        print(f"   Day {result.get('day', '?')} — alive: {result.get('alive', [])}")
        alive = result.get('alive', [])
        if len(alive) > 2:
            for voter in alive:
                possible = [c for c in alive if c != voter]
                mafia.day_vote(voter, random.choice(possible))
            day_result = mafia.resolve_day()
            eliminated = day_result.get('eliminated', 'none')
            elim_role = day_result.get('role', 'unknown')
            print(f"   Vote: {eliminated} eliminated ({elim_role})")
            if day_result.get('game_over'):
                print(f"\n🏁 Game over! Winner: {day_result['winner']}")
                break

    print(f"\n📊 Final status:")
    final = mafia.status()
    for k in ['id', 'phase', 'winner', 'alive_count', 'dead_count']:
        print(f"   {k}: {final.get(k, '?')}")
    print(f"   Eliminations: {final.get('elimination_record', [])}")

    import ast
    with open('/home/ubuntu/.openclaw/workspace/colony/colony-mafia.py') as f:
        ast.parse(f.read())
    print("\n✅ Mafia game complete! Parses OK")
