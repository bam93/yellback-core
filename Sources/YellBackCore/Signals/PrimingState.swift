import Foundation

/// Engine-owned state that makes detectors cross-sensitive when a trigger has
/// recently fired.
///
/// When any trigger fires, the engine enters a primed window. While primed, the
/// *other* triggers' thresholds are multiplied by a configurable factor,
/// making them easier to fire. The trigger that caused priming is NOT itself
/// easier to fire — this prevents auto-retrigger loops.
///
/// Detectors consult this state before firing rather than applying thresholds
/// independently. See `ARCHITECTURE.md` for full semantics.
struct PrimingState {}
