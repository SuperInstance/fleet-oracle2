/**
 * rotation-engine.js
 * ==================
 * 5th-engine decision module for the Rotation Oracle.
 *
 * Takes base system metrics + the last N decisions from the oracle,
 * computes a combined_confidence score (0.0–1.0) using a simple moving
 * average (SMA) of recent decisions for stability.
 *
 * Exports: { evaluate, train, reset }
 *
 * The "5th engine" is the meta-cognitive layer that sits above the
 * raw SVM prediction and the rotation-cognitive signal. It smooths
 * noisy individual decisions and provides a stable confidence envelope.
 */

'use strict';

// ─── Constants ────────────────────────────────────────────────────────────────

const SMA_WINDOW = 10;          // last N decisions for moving average
const MAX_CONFIDENCE = 1.0;
const MIN_CONFIDENCE = 0.0;

// Metric weight factors (tuned for a mixed workload cluster)
const WEIGHTS = {
  cpu:       0.20,   // system load contribution
  ram:       0.15,   // memory pressure contribution
  disk:      0.10,   // disk IO contribution
  uptime:    0.05,   // stability bonus (longer uptime → more trust)
  entropy:   0.25,   // decision entropy surprise weight
  rhythm:    0.15,   // rhythm anomaly weight
  svm:       0.10,   // SVM prediction confidence weight
};

// ─── State ────────────────────────────────────────────────────────────────────

/** @type {Array<{combined_confidence:number,rotation_confidence:number,decision_count:number,ts:number}>} */
const decisionHistory = [];

/** @type {number} */
let totalDecisions = 0;

/** @type {number} */
let rotationTotal = 0;

// ─── Internal helpers ────────────────────────────────────────────────────────

/**
 * Clamp a value to [min, max].
 * @param {number} val
 * @param {number} min
 * @param {number} max
 * @returns {number}
 */
function clamp(val, min, max) {
  return Math.max(min, Math.min(max, val));
}

/**
 * Simple Moving Average of the last N combined_confidence values.
 * @param {Array<{combined_confidence:number}>} history
 * @param {number} n
 * @returns {number}
 */
function sma(history, n) {
  const window = history.slice(-n);
  if (window.length === 0) return 0.5;
  const sum = window.reduce((acc, d) => acc + d.combined_confidence, 0);
  return sum / window.length;
}

/**
 * Normalise a 0–100 percentage to 0.0–1.0.
 * @param {number} pct
 * @returns {number}
 */
function normPct(pct) {
  return clamp(pct / 100, 0, 1);
}

/**
 * Normalise uptime in seconds to a 0.0–1.0 stability score.
 * Caps at 30 days (2592000 s) for full score.
 * @param {number} secs
 * @returns {number}
 */
function normUptime(secs) {
  const cap = 2592000;
  return clamp(secs / cap, 0, 1);
}

/**
 * Compute per-metric confidence contribution.
 * @param {object} metrics
 * @returns {number}
 */
function metricScore(metrics) {
  const { cpu, ram, disk, uptime } = metrics;

  const cpuScore   = normPct(100 - clamp(cpu, 0, 100));          // low cpu = high score
  const ramScore   = normPct(100 - clamp(ram, 0, 100));          // low ram = high score
  const diskScore  = normPct(100 - clamp(disk, 0, 100));         // low disk = high score
  const uptimeScore = normUptime(uptime || 0);

  return (
    WEIGHTS.cpu    * cpuScore +
    WEIGHTS.ram    * ramScore +
    WEIGHTS.disk   * diskScore +
    WEIGHTS.uptime * uptimeScore
  );
}

/**
 * Rolling standard deviation of the last N confidence values.
 * @param {Array<{combined_confidence:number}>} history
 * @param {number} n
 * @returns {number}
 */
function rollingStdDev(history, n) {
  const window = history.slice(-n);
  if (window.length < 2) return 0;
  const mean = window.reduce((a, d) => a + d.combined_confidence, 0) / window.length;
  const variance = window.reduce((a, d) => a + Math.pow(d.combined_confidence - mean, 2), 0) / window.length;
  return Math.sqrt(variance);
}

// ─── Public API ─────────────────────────────────────────────────────────────

/**
 * evaluate — main entry point
 * ---------------------------
 * Computes a combined_confidence score from current system metrics
 * and the rolling oracle decision history.
 *
 * @param {object} baseMetrics  – { cpu, ram, disk, uptime }
 * @param {object} [oracleState] – optional last oracle state for consistency check
 * @returns {object} decision result
 */
function evaluate(baseMetrics, oracleState) {
  const now = Date.now();
  totalDecisions++;

  const mScore = metricScore(baseMetrics);

  // Entropy & rhythm from oracle state (if provided)
  const entropy   = (oracleState && typeof oracleState.last_entropy_surprise === 'number')
    ? clamp(oracleState.last_entropy_surprise, 0, 1)
    : 0.5;
  const rhythm    = (oracleState && typeof oracleState.last_rhythm_anomaly === 'number')
    ? clamp(oracleState.last_rhythm_anomaly, 0, 1)
    : 0.5;
  const svmConf   = (oracleState && typeof oracleState.svm_confidence === 'number')
    ? oracleState.svm_confidence
    : 0.5;

  // Raw weighted score
  const rawScore =
    WEIGHTS.entropy * (1 - entropy) +
    WEIGHTS.rhythm  * (1 - rhythm)  +
    WEIGHTS.svm     * svmConf       +
    mScore;

  // Pull in SMA of last N decisions for stability
  const smaVal = sma(decisionHistory, SMA_WINDOW);

  // If we have enough history, blend raw score with SMA
  // (more history = more weight on the rolling average, less on raw)
  const historyRatio = Math.min(decisionHistory.length / SMA_WINDOW, 1.0);
  const combined_confidence = clamp(
    rawScore * (1 - historyRatio * 0.6) + smaVal * (historyRatio * 0.6),
    MIN_CONFIDENCE,
    MAX_CONFIDENCE
  );

  // Rotation cognitive: +1 = bullish rotation, -1 = bearish, 0 = neutral
  const rotationCognitive = combined_confidence > 0.75
    ? 1.0
    : combined_confidence < 0.35
      ? -1.0
      : 0.0;

  // Rotation confidence: how sure we are about the rotation direction
  // Higher when SMA is stable (low std dev) and we have a long history
  const stdDev = rollingStdDev(decisionHistory, SMA_WINDOW);
  const historyStability = 1 - clamp(stdDev * 4, 0, 1);
  const rotation_confidence = clamp(
    historyStability * combined_confidence,
    MIN_CONFIDENCE,
    MAX_CONFIDENCE
  );

  // Cycle error: deviation from expected rotation interval
  // (computed from consecutive high-confidence decisions)
  const rotation_cycle_error = computeCycleError();

  // Search similarity: how close this decision is to the SMA trend
  const search_similarity = clamp(
    1 - Math.abs(combined_confidence - smaVal) * 2,
    0,
    1
  );

  // Search vote: majority signal from last N decisions
  const search_vote = smaVal > 0.5 ? 1 : 0;

  // Needs attention flag
  const needs_attention = combined_confidence < 0.25 || rotation_confidence < 0.2;

  // Human-readable recommendation
  const recommendation = buildRecommendation({
    combined_confidence,
    rotation_confidence,
    rotationCognitive,
    needs_attention,
    historyLen: decisionHistory.length,
  });

  // Record this decision in history
  const entry = {
    combined_confidence,
    rotation_confidence,
    rotation_cognitive: rotationCognitive,
    decision_count: totalDecisions,
    ts: now,
  };
  decisionHistory.push(entry);

  // Trim history to window + buffer
  if (decisionHistory.length > SMA_WINDOW * 3) {
    decisionHistory.splice(0, decisionHistory.length - SMA_WINDOW * 3);
  }

  return {
    combined_confidence,
    rotation_confidence,
    rotation_cognitive: rotationCognitive,
    rotation_cycle_error,
    entropy_surprise: entropy,
    rhythm_anomaly: rhythm,
    svm_confidence: svmConf,
    svm_prediction: svmConf > 0.5 ? 1 : 0,
    search_similarity,
    search_vote,
    needs_attention,
    recommendation,
    metrics: baseMetrics,
    _debug: {
      mScore,
      smaVal,
      historyRatio,
      stdDev,
      historyStability,
      historyLen: decisionHistory.length,
    },
  };
}

/**
 * computeCycleError — measures deviation from expected rotation spacing.
 * Returns a normalised error value (0 = perfect spacing, higher = more error).
 */
function computeCycleError() {
  if (decisionHistory.length < 3) return 0;

  const recent = decisionHistory.slice(-5);
  const intervals = [];
  for (let i = 1; i < recent.length; i++) {
    intervals.push((recent[i].ts - recent[i - 1].ts) / 1000); // seconds
  }

  if (intervals.length === 0) return 0;
  const meanInterval = intervals.reduce((a, b) => a + b, 0) / intervals.length;
  const variance = intervals.reduce((a, t) => a + Math.pow(t - meanInterval, 2), 0) / intervals.length;
  const stdDev = Math.sqrt(variance);

  // Normalise: expected rotation interval ~60s; error >30s is concerning
  return clamp(stdDev / 30, 0, 5);
}

/**
 * buildRecommendation — human-readable decision summary.
 * @param {object} p
 * @returns {string}
 */
function buildRecommendation(p) {
  const { combined_confidence, rotation_confidence, rotationCognitive, needs_attention, historyLen } = p;

  if (needs_attention) {
    return `⚠️  LOW CONFIDENCE: combined=${combined_confidence.toFixed(3)}. rotation_confidence=${rotation_confidence.toFixed(3)}. manual inspection recommended.`;
  }
  if (rotationCognitive === 1 && rotation_confidence > 0.8) {
    return `✅ LOCAL CONSENSUS: system healthy. rotation_confidence=${rotation_confidence.toFixed(2)}. continue monitoring.`;
  }
  if (rotationCognitive === -1) {
    return `🔴 ROTATION BREAK: cycle_error elevated. rotation_confidence=${rotation_confidence.toFixed(3)}. investigate.`;
  }
  if (historyLen < SMA_WINDOW) {
    return `⏳ BUILDING CONFIDENCE: need more data. (${historyLen}/${SMA_WINDOW} decisions).`;
  }
  return `ℹ️  NEUTRAL: combined=${combined_confidence.toFixed(3)}. monitoring.`;
}

/**
 * train — incorporate an external labelled outcome to adjust weights.
 * This is a stub for future online learning; currently records the outcome.
 *
 * @param {{combined_confidence:number,outcome:number}} decision  – decision entry
 * @param {number} outcome  – 1 = positive (correct), 0 = neutral, -1 = negative
 */
function train(decision, outcome) {
  // Online weight adjustment: shift weights toward outcomes
  // This is a simple reward/penalty mechanism.
  const alpha = 0.05; // learning rate
  if (outcome > 0) {
    // Positive outcome: slightly increase confidence
    decision._rewarded = true;
  } else if (outcome < 0) {
    // Negative outcome: decrease confidence
    decision._penalised = true;
  }
  // In a full implementation, weights would be adjusted here.
  // For now we record the outcome for audit purposes.
  if (decision._debug) {
    decision._debug.lastOutcome = outcome;
  }
}

/**
 * reset — clear decision history and counters.
 */
function reset() {
  decisionHistory.length = 0;
  totalDecisions = 0;
  rotationTotal = 0;
}

// ─── Module exports ──────────────────────────────────────────────────────────

module.exports = { evaluate, train, reset, SMA_WINDOW };
