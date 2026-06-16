//! bottle_integration.rs
//!
//! Bridge between `ternary-fleet-integration` types and the `superinstance-protocol` Bottle.
//! Wraps AggregateResult into Bottle (encode) and decodes Bottle back into AggregateResult.
//!
//! Conservation law: the trits encode aggregate ternary sentiment.
//! trits[0] = accept, trits[1] = neutral, trits[2] = reject,
//! packed as -1/0/+1 relative to total.
//!
//! Usage:
//!   use superinstance_protocol::Bottle;
//!   use ternary_fleet_integration::ternary_aggregator::AggregateResult;
//!
//!   let result = aggregate_votes(&votes);
//!   let bottle = BottleIntegration::aggregate_to_bottle(
//!       "dash-relay", "fleet-dashboard", "fleet.consensus.update",
//!       &result, 60
//!   )?;
//!   let wire = bottle.encode()?;
//!
//!   // On the receiving end:
//!   let decoded: AggregateResult = BottleIntegration::bottle_to_aggregate(&bottle)?;

use rmp_serde;
use serde::{Deserialize, Serialize};
use superinstance_protocol::{Bottle, BottleError, Trit};

/// AggregateResult struct matching ternary-fleet-integration's.
/// Re-exported here so this bridge crate doesn't need a direct dep on ternary-fleet-integration.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AggregateResult {
    pub total: usize,
    pub accept: usize,
    pub neutral: usize,
    pub reject: usize,
    pub confidence: f64,
    pub net_sentiment: f64,
}

/// Bridge between AggregateResult and the Bottle protocol.
pub struct BottleIntegration;

impl BottleIntegration {
    /// Encode an AggregateResult into a Bottle.
    ///
    /// The `trits` are computed from the aggregate sentiment:
    /// - trits[0] = -1 if accept < 1, 0 if accept ≈ neutral, +1 if accept > reject
    /// - trits[1] = how close to consensus (confidence quantized)
    /// - trits[2] = general sentiment direction (-1 = net rejection, 0 = split, +1 = net accept)
    ///
    /// This encodes γ=η=C in the envelope trits for routing without payload deserialisation.
    pub fn aggregate_to_bottle(
        src: impl Into<String>,
        tgt: impl Into<String>,
        act: impl Into<String>,
        result: &AggregateResult,
        ttl: u32,
    ) -> Result<Bottle, BottleError> {
        let trits = Self::compute_trits(result);
        Bottle::new(src, tgt, act, trits, result, ttl)
    }

    /// Decode a Bottle back into an AggregateResult.
    pub fn bottle_to_aggregate(bottle: &Bottle) -> Result<AggregateResult, BottleError> {
        bottle.decode_payload()
    }

    /// Verify conservation: checks that the decoded AggregateResult's net_sentiment
    /// matches the envelope trits' encoded sentiment.
    pub fn validate_conservation(
        input: &Bottle,
        output: &Bottle,
    ) -> Result<(), BottleError> {
        superinstance_protocol::audit_strict(input, output)
    }

    /// Compute envelope trits from an AggregateResult.
    ///
    /// trits[0]: relative acceptance (-1 = rejected, 0 = neutral, +1 = accepted)
    /// trits[1]: confidence quantized (-1 = low/no consensus, 0 = moderate, +1 = high/strict)
    /// trits[2]: field reserved for conservation chain continuity (starts 0)
    fn compute_trits(result: &AggregateResult) -> Vec<Trit> {
        let t0: Trit = if result.accept > result.reject {
            if result.accept > result.total / 2 {
                1  // clear acceptance
            } else {
                0  // slight preference but not majority
            }
        } else if result.reject > result.accept {
            if result.reject > result.total / 2 {
                -1  // clear rejection
            } else {
                0  // slight rejection but not majority
            }
        } else {
            0  // exactly split or no votes
        };

        // t1: confidence quantized
        let t1: Trit = if result.total == 0 {
            0
        } else if result.confidence >= 0.66 {
            1  // high confidence — strict consensus
        } else if result.confidence >= 0.33 {
            0  // moderate confidence
        } else {
            -1  // low confidence — completely split
        };

        // t2: net sentiment direction — -1 from 0, or net_sentiment quantized
        let t2: Trit = if result.net_sentiment > 0.10 {
            1
        } else if result.net_sentiment < -0.10 {
            -1
        } else {
            0
        };

        vec![t0, t1, t2]
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aggregate_bottle_roundtrip() {
        let result = AggregateResult {
            total: 10,
            accept: 7,
            neutral: 2,
            reject: 1,
            confidence: 0.7,
            net_sentiment: 0.6,
        };

        let bottle = BottleIntegration::aggregate_to_bottle(
            "dash-relay", "fleet-dashboard", "fleet.consensus.update",
            &result, 60,
        ).unwrap();

        // Verify envelope trits
        assert_eq!(bottle.trits, vec![1, 1, 1]);
        assert_eq!(bottle.src, "dash-relay");
        assert_eq!(bottle.tgt, "fleet-dashboard");
        assert_eq!(bottle.act, "fleet.consensus.update");

        // Decode back
        let decoded: AggregateResult = BottleIntegration::bottle_to_aggregate(&bottle).unwrap();
        assert_eq!(decoded.total, result.total);
        assert_eq!(decoded.accept, result.accept);
        assert_eq!(decoded.neutral, result.neutral);
        assert_eq!(decoded.reject, result.reject);
        assert!((decoded.confidence - result.confidence).abs() < 0.01);
        assert!((decoded.net_sentiment - result.net_sentiment).abs() < 0.01);
    }

    #[test]
    fn broad_rejection_trits() {
        let result = AggregateResult {
            total: 10,
            accept: 1,
            neutral: 1,
            reject: 8,
            confidence: 0.8,
            net_sentiment: -0.7,
        };
        let bottle = BottleIntegration::aggregate_to_bottle(
            "sensor", "dash", "fleet.consensus", &result, 60,
        ).unwrap();
        assert_eq!(bottle.trits, vec![-1, 1, -1]);
    }

    #[test]
    fn exact_split_trits() {
        let result = AggregateResult {
            total: 10,
            accept: 5,
            neutral: 0,
            reject: 5,
            confidence: 0.5,
            net_sentiment: 0.0,
        };
        let bottle = BottleIntegration::aggregate_to_bottle(
            "sensor", "dash", "fleet.consensus", &result, 60,
        ).unwrap();
        assert_eq!(bottle.trits, vec![0, 0, 0]);
    }

    #[test]
    fn no_votes_trits() {
        let result = AggregateResult {
            total: 0,
            accept: 0,
            neutral: 0,
            reject: 0,
            confidence: 0.0,
            net_sentiment: 0.0,
        };
        let bottle = BottleIntegration::aggregate_to_bottle(
            "sensor", "dash", "fleet.consensus", &result, 60,
        ).unwrap();
        assert_eq!(bottle.trits, vec![0, 0, 0]);
    }

    #[test]
    fn conservation_preserved() {
        let input = AggregateResult {
            total: 10, accept: 7, neutral: 2, reject: 1,
            confidence: 0.7, net_sentiment: 0.6,
        };
        let output = AggregateResult {
            total: 10, accept: 7, neutral: 2, reject: 1,
            confidence: 0.7, net_sentiment: 0.6,
        };

        let input_bottle = BottleIntegration::aggregate_to_bottle(
            "a", "b", "step1", &input, 60,
        ).unwrap();
        let output_bottle = BottleIntegration::aggregate_to_bottle(
            "b", "c", "step2", &output, 60,
        ).unwrap();

        assert!(BottleIntegration::validate_conservation(&input_bottle, &output_bottle).is_ok());
    }

    #[test]
    fn conservation_violation_detected() {
        let result_a = AggregateResult {
            total: 5, accept: 3, neutral: 1, reject: 1,
            confidence: 0.6, net_sentiment: 0.4,
        };
        let result_b = AggregateResult {
            total: 5, accept: 0, neutral: 0, reject: 5,
            confidence: 1.0, net_sentiment: -1.0,
        };

        let input = BottleIntegration::aggregate_to_bottle(
            "a", "b", "step1", &result_a, 60,
        ).unwrap();
        let output = BottleIntegration::aggregate_to_bottle(
            "b", "c", "step2", &result_b, 60,
        ).unwrap();

        assert!(BottleIntegration::validate_conservation(&input, &output).is_err());
    }
}
