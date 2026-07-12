use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

/// A single agent workload report.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Report {
    pub agent: String,
    pub gamma: u64,
    pub eta: u64,
    pub task: String,
    pub timestamp: String,
}

impl Report {
    /// The conservation constant: γ + η = C
    pub fn c(&self) -> u64 {
        self.gamma + self.eta
    }

    /// γ / η ratio as f64 (avoiding div by zero)
    pub fn gamma_ratio(&self) -> f64 {
        if self.eta == 0 {
            f64::MAX
        } else {
            self.gamma as f64 / self.eta as f64
        }
    }
}

/// Ring buffer of reports with rolling computations.
pub struct MetricStore {
    pub reports: VecDeque<Report>,
    max_history: usize,
}

#[derive(Debug, Serialize)]
pub struct Status {
    pub total_reports: usize,
    pub current_c: f64,
    pub ratio: f64,
    pub ratio_color: String,
    pub burn_detected: bool,
    pub gamma_trend: Vec<u64>,
    pub eta_trend: Vec<u64>,
    pub c_trend: Vec<u64>,
    pub recent_reports: Vec<Report>,
}

impl MetricStore {
    pub fn new(max_history: usize) -> Self {
        Self {
            reports: VecDeque::with_capacity(max_history),
            max_history,
        }
    }

    pub fn push(&mut self, report: Report) {
        if self.reports.len() >= self.max_history {
            self.reports.pop_front();
        }
        self.reports.push_back(report);
    }

    /// Prune entries older than `hours`.
    pub fn prune_older_than(&mut self, hours: i64) {
        let cutoff = Utc::now() - chrono::Duration::hours(hours);
        self.reports.retain(|r| {
            DateTime::parse_from_rfc3339(&r.timestamp)
                .map(|dt| dt.with_timezone(&Utc) >= cutoff)
                .unwrap_or(true) // keep if unparseable
        });
    }

    fn avg_c(&self) -> f64 {
        let count = self.reports.len();
        if count == 0 {
            return 0.0;
        }
        self.reports.iter().map(|r| r.c()).sum::<u64>() as f64 / count as f64
    }

    fn avg_ratio(&self) -> f64 {
        let count = self.reports.len();
        if count == 0 {
            return 0.0;
        }
        let non_zero: Vec<_> = self.reports.iter().filter(|r| r.eta > 0).collect();
        if non_zero.is_empty() {
            return 0.0;
        }
        non_zero.iter().map(|r| r.gamma as f64 / r.eta as f64).sum::<f64>() / non_zero.len() as f64
    }

    /// Burn signal: recent γ rising while η stays flat (±2).
    ///
    /// "Rising" means *strictly* increasing — a perfectly stable system (all γ
    /// equal, all η equal) must NOT register as a burn. The previous `>=` made
    /// every flat window count as "rising", producing a false burn alarm on a
    /// healthy, idle box and forcing maximum GC aggression via the self-tuner.
    pub fn detect_burn(&self) -> bool {
        if self.reports.len() < 5 {
            return false;
        }
        let recent: Vec<_> = self.reports.iter().rev().take(5).collect();
        // recent[0] is newest, recent[4] is oldest. "Rising" = each step strictly
        // greater than the one before (newer > older when read oldest→newest).
        let gamma_rising = recent.windows(2).all(|w| w[0].gamma > w[1].gamma);
        let eta_flat = recent
            .windows(2)
            .all(|w| (w[0].eta as i64 - w[1].eta as i64).abs() <= 2);
        gamma_rising && eta_flat
    }

    fn ratio_color(&self) -> String {
        let r = self.avg_ratio();
        if r < 5.0 {
            "#00FF88".to_string()
        } else if r < 15.0 {
            "#E8883A".to_string()
        } else {
            "#8B4513".to_string()
        }
    }

    fn trend_vec(&self, extract: fn(&Report) -> u64, count: usize) -> Vec<u64> {
        self.reports
            .iter()
            .rev()
            .take(count)
            .map(extract)
            .collect()
    }

    pub fn status(&self) -> Status {
        let trend_count = 30usize.min(self.reports.len());
        Status {
            total_reports: self.reports.len(),
            current_c: self.avg_c(),
            ratio: self.avg_ratio(),
            ratio_color: self.ratio_color(),
            burn_detected: self.detect_burn(),
            gamma_trend: self.trend_vec(|r| r.gamma, trend_count),
            eta_trend: self.trend_vec(|r| r.eta, trend_count),
            c_trend: self.trend_vec(|r| r.c(), trend_count),
            recent_reports: self.reports.iter().rev().take(20).cloned().collect(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rpt(gamma: u64, eta: u64) -> Report {
        Report {
            agent: "test".into(),
            gamma,
            eta,
            task: "t".into(),
            timestamp: "2026-07-11T00:00:00Z".into(),
        }
    }

    #[test]
    fn c_is_gamma_plus_eta() {
        assert_eq!(rpt(634, 340).c(), 974);
    }

    #[test]
    fn gamma_ratio_avoids_div_by_zero() {
        assert_eq!(rpt(634, 0).gamma_ratio(), f64::MAX);
        assert!((rpt(634, 340).gamma_ratio() - 1.8647058823529412).abs() < 1e-9);
    }

    #[test]
    fn detect_burn_false_on_flat_stable_system() {
        // A perfectly stable system: identical γ and η across all reports.
        // This MUST NOT register as a burn. (Previously returned true due to `>=`.)
        let mut store = MetricStore::new(100);
        for _ in 0..5 {
            store.push(rpt(800, 400));
        }
        assert!(!store.detect_burn(), "stable system flagged as burning");
    }

    #[test]
    fn detect_burn_true_on_strictly_rising_gamma_flat_eta() {
        // γ strictly increasing each step, η flat → genuine burn.
        let mut store = MetricStore::new(100);
        // Push oldest→newest; detect_burn reads newest first internally.
        for g in [100u64, 120, 140, 160, 180] {
            store.push(rpt(g, 400));
        }
        assert!(store.detect_burn(), "rising γ with flat η should burn");
    }

    #[test]
    fn detect_burn_false_when_eta_is_not_flat() {
        // γ rising but η also moving → not a burn (effort is scaling too).
        let mut store = MetricStore::new(100);
        for (g, e) in [(100u64, 400), (120, 410), (140, 420), (160, 430), (180, 440)] {
            store.push(rpt(g, e));
        }
        assert!(!store.detect_burn());
    }

    #[test]
    fn detect_burn_false_with_too_few_reports() {
        let mut store = MetricStore::new(100);
        store.push(rpt(100, 400));
        assert!(!store.detect_burn());
    }

    #[test]
    fn ring_buffer_evicts_oldest() {
        let mut store = MetricStore::new(3);
        store.push(rpt(1, 1));
        store.push(rpt(2, 1));
        store.push(rpt(3, 1));
        store.push(rpt(4, 1));
        assert_eq!(store.reports.len(), 3);
        assert_eq!(store.reports.front().unwrap().gamma, 2);
        assert_eq!(store.reports.back().unwrap().gamma, 4);
    }
}
