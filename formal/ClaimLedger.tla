------------------------------ MODULE ClaimLedger ------------------------------
EXTENDS Integers, FiniteSets

(*
Bounded Apalache model of the Gitomi claim/lease protocol (spec/08_CLAIMS.md).

The model abstracts away ref plumbing, signatures, JSON, and path globbing. It
keeps exactly the machinery that decides whether two actors can end up mutating
overlapping paths at the same time:

  - a single ledger advanced by compare-and-swap (spec 08 SS9.1),
  - wall-clock leases with per-actor clock skew (SS8.1, SS8.2),
  - lease_seq fencing at the gate (SS8.3),
  - delta authorization for reaping other actors' claims (SS6),
  - reader/writer conflict semantics (SS7.1).

"Critical section" (CS) models the window in which an actor is actually
mutating the paths it claimed. The top-level property is that two actors are
never in overlapping critical sections unless both are readers.

Each CONSTANT switches one spec requirement on or off, so that turning it off
is expected to produce a counterexample. That is the point: it demonstrates the
clause is load-bearing rather than decorative.

  AtomicCAS:
    TRUE  => a claim is committed only if the ledger has not moved since the
             conflict check, and the check is re-run at commit (SS9.1 step 7).
    FALSE => check-then-act: two actors may both commit after both observed a
             free resource.

  UseFencing:
    TRUE  => entering the CS re-reads the ledger and requires holder and
             lease_seq to still match the captured token (SS8.3).
    FALSE => the actor proceeds on its own belief that it holds the lease.

  DeltaAuth:
    TRUE  => an actor may delete another actor's claim only if that claim is
             expired under the peer rule (SS6, deletion case b).
    FALSE => any actor may delete any claim.

  SkewAsymmetry:
    TRUE  => peer expiry applies the skew allowance (reap late), own expiry
             does not (die early) (SS8.2).
    FALSE => both judgments use the raw clock comparison.

  SkewAllow:
    The skew allowance in ticks. The model is used to show this must be at
    least 2 * MaxSkew, not merely positive.

  CSWatchdog:
    TRUE  => time cannot advance past the point where an in-CS actor's own
             lease would expire; models an implementation that renews or
             aborts before its own deadline.
    FALSE => leases may expire underneath an actor that is mid-mutation.
*)

CONSTANTS
  (* @type: Bool; *)
  AtomicCAS,
  (* @type: Bool; *)
  UseFencing,
  (* @type: Bool; *)
  DeltaAuth,
  (* @type: Bool; *)
  SkewAsymmetry,
  (* @type: Int; *)
  SkewAllow,
  (* @type: Bool; *)
  CSWatchdog

Actors    == {"a1", "a2"}
Resources == {"r1", "r2"}
ClaimIds  == {"c1", "c2", "c3"}
Modes     == {"read", "write"}

NoneActor == "noActor"
NoneClaim == "noClaim"
NoneMode  == "noMode"

MaxTime  == 5
MaxSkew  == 1
Offsets  == {-1, 0, 1}
LeaseDur == 2

\* Enumerated instead of SUBSET Resources \ {{}} to keep the encoding small.
PathSets == {{"r1"}, {"r2"}, {"r1", "r2"}}

EmptyPaths == {"r1"} \ {"r1"}

VARIABLES
  (* @type: Int; *)
  now,
  (* @type: Str -> Int; *)
  offset,
  (* @type: Str -> Str; *)
  cHolder,
  (* @type: Str -> Str; *)
  cMode,
  (* @type: Str -> Set(Str); *)
  cPaths,
  (* @type: Str -> Int; *)
  cExp,
  (* @type: Str -> Int; *)
  cSeq,
  (* @type: Int; *)
  ledgerVer,
  (* @type: Str -> Str; *)
  heldId,
  (* @type: Str -> Int; *)
  heldSeq,
  (* @type: Str -> Set(Str); *)
  heldPaths,
  (* @type: Str -> Str; *)
  heldMode,
  (* @type: Str -> Int; *)
  heldExp,
  (* @type: Str -> Str; *)
  csMode,
  (* @type: Str -> Set(Str); *)
  csPaths,
  (* @type: Str -> Str; *)
  stgId,
  (* @type: Str -> Set(Str); *)
  stgPaths,
  (* @type: Str -> Str; *)
  stgMode,
  (* @type: Str -> Int; *)
  stgVer

vars == <<now, offset, cHolder, cMode, cPaths, cExp, cSeq, ledgerVer,
          heldId, heldSeq, heldPaths, heldMode, heldExp,
          csMode, csPaths, stgId, stgPaths, stgMode, stgVer>>

--------------------------------------------------------------------------------
(* Clocks and expiry *)

\* @type: (Str) => Int;
View(a) == now + offset[a]

\* Expiry has no global frame: expires_at is written in the holder's clock
\* frame, so the only well-defined ground truth for "this lease is really
\* over" is the holder's own view of its own deadline. Used by invariants
\* only, never by an action guard.
\* @type: (Str) => Bool;
HolderExpired(c) ==
  IF cHolder[c] = NoneActor
  THEN TRUE
  ELSE cExp[c] <= now + offset[cHolder[c]]

\* SS8.1 / SS8.2: an actor judges its OWN lease dead early (no grace).
\* @type: (Str) => Bool;
OwnExpired(a) == heldExp[a] <= View(a)

\* SS8.2: an actor judges a PEER's lease dead late (grace applied).
\* @type: (Str, Str) => Bool;
PeerExpired(a, c) ==
  IF SkewAsymmetry
  THEN cExp[c] + SkewAllow <= View(a)
  ELSE cExp[c] <= View(a)

--------------------------------------------------------------------------------
(* Conflict, SS7.1 *)

\* Does claim c, as seen by actor a, block a request for path set s in mode m?
\* @type: (Str, Set(Str), Str, Str) => Bool;
Blocks(a, s, m, c) ==
  /\ cHolder[c] # NoneActor
  /\ cHolder[c] # a
  /\ ~PeerExpired(a, c)
  /\ cPaths[c] \cap s # EmptyPaths
  /\ (m = "write" \/ cMode[c] = "write")

\* @type: (Str, Set(Str), Str) => Bool;
Free(a, s, m) == \A c \in ClaimIds: ~Blocks(a, s, m, c)

--------------------------------------------------------------------------------
(* Initial state *)

TypeOK ==
  /\ AtomicCAS \in BOOLEAN
  /\ UseFencing \in BOOLEAN
  /\ DeltaAuth \in BOOLEAN
  /\ SkewAsymmetry \in BOOLEAN
  /\ CSWatchdog \in BOOLEAN
  /\ SkewAllow \in 0..4
  /\ now \in 0..MaxTime
  /\ offset \in [Actors \cup {NoneActor} -> Offsets]
  /\ cHolder \in [ClaimIds -> Actors \cup {NoneActor}]
  /\ cMode \in [ClaimIds -> Modes \cup {NoneMode}]
  /\ cPaths \in [ClaimIds -> SUBSET Resources]
  /\ cExp \in [ClaimIds -> -4..(MaxTime + LeaseDur + MaxSkew)]
  /\ cSeq \in [ClaimIds -> 0..(MaxTime + 2)]
  /\ ledgerVer \in 0..(4 * MaxTime + 4)
  /\ heldId \in [Actors -> ClaimIds \cup {NoneClaim}]
  /\ heldSeq \in [Actors -> 0..(MaxTime + 2)]
  /\ heldPaths \in [Actors -> SUBSET Resources]
  /\ heldMode \in [Actors -> Modes \cup {NoneMode}]
  /\ heldExp \in [Actors -> -4..(MaxTime + LeaseDur + MaxSkew)]
  /\ csMode \in [Actors -> Modes \cup {NoneMode}]
  /\ csPaths \in [Actors -> SUBSET Resources]
  /\ stgId \in [Actors -> ClaimIds \cup {NoneClaim}]
  /\ stgPaths \in [Actors -> SUBSET Resources]
  /\ stgMode \in [Actors -> Modes \cup {NoneMode}]
  /\ stgVer \in [Actors -> 0..(4 * MaxTime + 4)]

Init ==
  /\ now = 0
  /\ offset \in [Actors \cup {NoneActor} -> Offsets]
  /\ cHolder = [c \in ClaimIds |-> NoneActor]
  /\ cMode = [c \in ClaimIds |-> NoneMode]
  /\ cPaths = [c \in ClaimIds |-> EmptyPaths]
  /\ cExp = [c \in ClaimIds |-> 0]
  /\ cSeq = [c \in ClaimIds |-> 0]
  /\ ledgerVer = 0
  /\ heldId = [a \in Actors |-> NoneClaim]
  /\ heldSeq = [a \in Actors |-> 0]
  /\ heldPaths = [a \in Actors |-> EmptyPaths]
  /\ heldMode = [a \in Actors |-> NoneMode]
  /\ heldExp = [a \in Actors |-> 0]
  /\ csMode = [a \in Actors |-> NoneMode]
  /\ csPaths = [a \in Actors |-> EmptyPaths]
  /\ stgId = [a \in Actors |-> NoneClaim]
  /\ stgPaths = [a \in Actors |-> EmptyPaths]
  /\ stgMode = [a \in Actors |-> NoneMode]
  /\ stgVer = [a \in Actors |-> 0]

--------------------------------------------------------------------------------
(* Actions *)

\* Time advances. With CSWatchdog, an actor inside its critical section is
\* assumed to renew or abort before its own deadline, so time may not step
\* over that deadline.
Tick ==
  /\ now < MaxTime
  /\ (CSWatchdog =>
        \A a \in Actors:
          csMode[a] # NoneMode => heldExp[a] > now + 1 + offset[a])
  /\ now' = now + 1
  /\ UNCHANGED <<offset, cHolder, cMode, cPaths, cExp, cSeq, ledgerVer,
            heldId, heldSeq, heldPaths, heldMode, heldExp, csMode,
            csPaths, stgId, stgPaths, stgMode, stgVer>>

\* SS9.1 steps 1-5: read the tip, check conflict, build the new claim.
PrepareAcquire ==
  \E a \in Actors:
    \E c \in ClaimIds:
      \E s \in PathSets:
        \E m \in Modes:
          /\ heldId[a] = NoneClaim
          /\ stgId[a] = NoneClaim
          /\ csMode[a] = NoneMode
          /\ cHolder[c] = NoneActor
          /\ Free(a, s, m)
          /\ stgId' = [stgId EXCEPT ![a] = c]
          /\ stgPaths' = [stgPaths EXCEPT ![a] = s]
          /\ stgMode' = [stgMode EXCEPT ![a] = m]
          /\ stgVer' = [stgVer EXCEPT ![a] = ledgerVer]
          /\ UNCHANGED <<now, offset, cHolder, cMode, cPaths, cExp, cSeq, ledgerVer,
            heldId, heldSeq, heldPaths, heldMode, heldExp, csMode,
            csPaths>>

\* SS9.1 step 7: the compare-and-swap. AtomicCAS is the CAS guard.
CommitAcquire ==
  \E a \in Actors:
    LET c == stgId[a] IN
    /\ c # NoneClaim
    /\ (AtomicCAS =>
          /\ stgVer[a] = ledgerVer
          /\ cHolder[c] = NoneActor
          /\ Free(a, stgPaths[a], stgMode[a]))
    /\ cHolder' = [cHolder EXCEPT ![c] = a]
    /\ cMode' = [cMode EXCEPT ![c] = stgMode[a]]
    /\ cPaths' = [cPaths EXCEPT ![c] = stgPaths[a]]
    /\ cExp' = [cExp EXCEPT ![c] = View(a) + LeaseDur]
    /\ cSeq' = [cSeq EXCEPT ![c] = 1]
    /\ ledgerVer' = ledgerVer + 1
    /\ heldId' = [heldId EXCEPT ![a] = c]
    /\ heldSeq' = [heldSeq EXCEPT ![a] = 1]
    /\ heldPaths' = [heldPaths EXCEPT ![a] = stgPaths[a]]
    /\ heldMode' = [heldMode EXCEPT ![a] = stgMode[a]]
    /\ heldExp' = [heldExp EXCEPT ![a] = View(a) + LeaseDur]
    /\ stgId' = [stgId EXCEPT ![a] = NoneClaim]
    /\ UNCHANGED <<now, offset, csMode, csPaths, stgPaths, stgMode, stgVer>>

\* SS9.2: the CAS failed, drop the staged attempt and retry later.
AbortStage ==
  \E a \in Actors:
    /\ stgId[a] # NoneClaim
    /\ stgId' = [stgId EXCEPT ![a] = NoneClaim]
    /\ UNCHANGED <<now, offset, cHolder, cMode, cPaths, cExp, cSeq, ledgerVer,
            heldId, heldSeq, heldPaths, heldMode, heldExp, csMode,
            csPaths, stgPaths, stgMode, stgVer>>

\* SS8.4. An expired lease MUST NOT be renewed (SS8.1).
Renew ==
  \E a \in Actors:
    LET c == heldId[a] IN
    /\ c # NoneClaim
    /\ cHolder[c] = a
    /\ cSeq[c] = heldSeq[a]
    /\ ~OwnExpired(a)
    /\ cExp' = [cExp EXCEPT ![c] = View(a) + LeaseDur]
    /\ cSeq' = [cSeq EXCEPT ![c] = cSeq[c] + 1]
    /\ ledgerVer' = ledgerVer + 1
    /\ heldSeq' = [heldSeq EXCEPT ![a] = cSeq[c] + 1]
    /\ heldExp' = [heldExp EXCEPT ![a] = View(a) + LeaseDur]
    /\ UNCHANGED <<now, offset, cHolder, cMode, cPaths, heldId, heldPaths,
            heldMode, csMode, csPaths, stgId, stgPaths, stgMode, stgVer>>

Release ==
  \E a \in Actors:
    LET c == heldId[a] IN
    /\ c # NoneClaim
    /\ csMode[a] = NoneMode
    /\ cHolder[c] = a
    /\ cHolder' = [cHolder EXCEPT ![c] = NoneActor]
    /\ cMode' = [cMode EXCEPT ![c] = NoneMode]
    /\ cPaths' = [cPaths EXCEPT ![c] = EmptyPaths]
    /\ cExp' = [cExp EXCEPT ![c] = 0]
    /\ cSeq' = [cSeq EXCEPT ![c] = 0]
    /\ ledgerVer' = ledgerVer + 1
    /\ heldId' = [heldId EXCEPT ![a] = NoneClaim]
    /\ heldMode' = [heldMode EXCEPT ![a] = NoneMode]
    /\ heldPaths' = [heldPaths EXCEPT ![a] = EmptyPaths]
    /\ UNCHANGED <<now, offset, heldSeq, heldExp, csMode, csPaths, stgId,
            stgPaths, stgMode, stgVer>>

\* SS6 deletion case (b): reaping an expired peer claim. DeltaAuth is the
\* authorization guard on the tree diff.
Reap ==
  \E a \in Actors:
    \E c \in ClaimIds:
      /\ cHolder[c] # NoneActor
      /\ cHolder[c] # a
      /\ (DeltaAuth => PeerExpired(a, c))
      /\ cHolder' = [cHolder EXCEPT ![c] = NoneActor]
      /\ cMode' = [cMode EXCEPT ![c] = NoneMode]
      /\ cPaths' = [cPaths EXCEPT ![c] = EmptyPaths]
      /\ cExp' = [cExp EXCEPT ![c] = 0]
      /\ cSeq' = [cSeq EXCEPT ![c] = 0]
      /\ ledgerVer' = ledgerVer + 1
      /\ UNCHANGED <<now, offset, heldId, heldSeq, heldPaths, heldMode, heldExp,
            csMode, csPaths, stgId, stgPaths, stgMode, stgVer>>

\* SS8.3: the fenced gate. This is the only way into the critical section.
EnterCS ==
  \E a \in Actors:
    LET c == heldId[a] IN
    /\ c # NoneClaim
    /\ csMode[a] = NoneMode
    /\ (UseFencing =>
          /\ cHolder[c] = a
          /\ cSeq[c] = heldSeq[a]
          /\ ~OwnExpired(a))
    /\ csMode' = [csMode EXCEPT ![a] = heldMode[a]]
    /\ csPaths' = [csPaths EXCEPT ![a] = heldPaths[a]]
    /\ UNCHANGED <<now, offset, cHolder, cMode, cPaths, cExp, cSeq, ledgerVer,
            heldId, heldSeq, heldPaths, heldMode, heldExp, stgId,
            stgPaths, stgMode, stgVer>>

ExitCS ==
  \E a \in Actors:
    /\ csMode[a] # NoneMode
    /\ csMode' = [csMode EXCEPT ![a] = NoneMode]
    /\ csPaths' = [csPaths EXCEPT ![a] = EmptyPaths]
    /\ UNCHANGED <<now, offset, cHolder, cMode, cPaths, cExp, cSeq, ledgerVer,
            heldId, heldSeq, heldPaths, heldMode, heldExp, stgId,
            stgPaths, stgMode, stgVer>>

Idle ==
  /\ now = MaxTime
  /\ UNCHANGED vars

Next ==
  \/ Tick
  \/ PrepareAcquire
  \/ CommitAcquire
  \/ AbortStage
  \/ Renew
  \/ Release
  \/ Reap
  \/ EnterCS
  \/ ExitCS
  \/ Idle

Spec == Init /\ [][Next]_vars

--------------------------------------------------------------------------------
(* Properties *)

\* The top-level goal. Two actors must never mutate overlapping paths at the
\* same time unless both are readers (SS7.1).
MutualExclusion ==
  \A a \in Actors:
    \A b \in Actors:
      (/\ a # b
       /\ csMode[a] # NoneMode
       /\ csMode[b] # NoneMode
       /\ csPaths[a] \cap csPaths[b] # EmptyPaths)
      => (csMode[a] = "read" /\ csMode[b] = "read")

\* SS7.2: conflict-freedom is an invariant of the ledger itself, not just a
\* convention of well-behaved clients. Judged against ground-truth time.
LedgerConflictFree ==
  \A c \in ClaimIds:
    \A d \in ClaimIds:
      (/\ c # d
       /\ cHolder[c] # NoneActor
       /\ cHolder[d] # NoneActor
       /\ cHolder[c] # cHolder[d]
       /\ ~HolderExpired(c)
       /\ ~HolderExpired(d)
       /\ cPaths[c] \cap cPaths[d] # EmptyPaths)
      => (cMode[c] = "read" /\ cMode[d] = "read")

\* SS8.2: a claim must never be removed while its holder still believes the
\* lease is live. This is the property the asymmetric skew rule protects, and
\* it is what makes the skew allowance a function of the skew bound.
NoPrematureReap ==
  \A a \in Actors:
    (/\ heldId[a] # NoneClaim
     /\ ~OwnExpired(a))
    => (/\ cHolder[heldId[a]] = a
        /\ cSeq[heldId[a]] = heldSeq[a])

\* SS8.3: an actor inside the critical section still genuinely owns the lease
\* it entered under. Distinguishes fencing at the transition from protection
\* for the whole duration.
CSLeaseValid ==
  \A a \in Actors:
    csMode[a] # NoneMode =>
      (/\ heldId[a] # NoneClaim
       /\ cHolder[heldId[a]] = a
       /\ cSeq[heldId[a]] = heldSeq[a]
       /\ ~OwnExpired(a))

Safety ==
  /\ MutualExclusion
  /\ LedgerConflictFree
  /\ NoPrematureReap
  /\ CSLeaseValid

================================================================================
