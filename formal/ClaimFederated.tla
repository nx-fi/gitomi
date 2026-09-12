----------------------------- MODULE ClaimFederated -----------------------------
EXTENDS Integers, FiniteSets

(*
Bounded Apalache model of the FEDERATED deployment mode of the Gitomi
claim/lease protocol (spec/08_CLAIMS.md SS9.3, SS7.3, SS11.2).

`ClaimLedger.tla` models `single-store`: all actors share one ref store, so a
local compare-and-swap is a true lock. This module models the other mode, where
each actor holds its own clone and the ledger is exchanged through a remote.
The lock is no longer local: a claim is only established once the ledger ref has
been pushed, and every replica's view of the ledger lags the remote.

What changes relative to the single-store model:

  - The remote holds the authoritative ledger. Each actor tracks `base`, the
    remote version its replica last fetched.
  - An actor's conflict check runs against its own STALE replica, so it cannot
    see a peer's claim that was pushed after its last fetch, and it cannot see a
    peer's claim that has not been pushed at all.
  - A push succeeds only if the remote has not moved (fast-forward). A rejected
    push forces a fetch and a re-derivation of the pending claim.
  - Claim records are never deleted from the model's remote, only marked with a
    removal version, so that a stale replica can still observe a claim that has
    already been removed upstream. Modelling removal as immediately visible
    would make replicas fresher than reality and would hide bugs.

Claim slots are single-use, standing in for UUID uniqueness: a slot that has
ever been created is never reused.

Constants, each disabling one requirement:

  RequireEstablished:
    TRUE  => a gated operation may only begin after the claim's ledger push has
             succeeded (SS7.3).
    FALSE => a locally committed claim is treated as held.

  FFOnPush:
    TRUE  => a push is refused unless the replica is up to date with the remote
             (SS11.2 fast-forward).
    FALSE => the replica may publish from a stale base.

  RevalidateOnRebase:
    TRUE  => after a fetch, an unestablished claim that now conflicts with the
             fetched tip is dropped and the operation aborted (SS11.2
             "re-derive its own pending claims onto the fetched tip").
    FALSE => the pending claim survives the rebase unexamined.

  FetchBeforeFence:
    TRUE  => the fence (SS8.4) requires an up-to-date replica.
    FALSE => the fence reads whatever the replica last fetched.

  AllowSteal:
    TRUE  => SS6 deletion case (c) is enabled: an administrator may remove a
             live claim it does not hold.
    FALSE => only expiry-based reaping (case b) is available.

  SafeSteal:
    TRUE  => a steal REVOKES the claim (blocking renewal) but does not remove
             it; removal happens through the ordinary expiry path, so the
             victim's SS8.5 deadline obligation guarantees it has stopped.
    FALSE => a steal deletes a live claim immediately.

Skew handling (SS8.3) and the deadline obligation (SS8.5) are hardcoded to
their correct behaviour here; they are exercised as knobs in ClaimLedger.tla.
*)

CONSTANTS
  (* @type: Bool; *)
  RequireEstablished,
  (* @type: Bool; *)
  FFOnPush,
  (* @type: Bool; *)
  RevalidateOnRebase,
  (* @type: Bool; *)
  FetchBeforeFence,
  (* @type: Bool; *)
  AllowSteal,
  (* @type: Bool; *)
  SafeSteal

Actors    == {"a1", "a2"}
Resources == {"r1", "r2"}
ClaimIds  == {"c1", "c2", "c3"}
Modes     == {"read", "write"}

NoneActor == "noActor"
NoneClaim == "noClaim"
NoneMode  == "noMode"

MaxTime   == 3
MaxVer    == 5
MaxSkew   == 1
SkewAllow == 2
Offsets   == {-1, 0, 1}
LeaseDur  == 2

PathSets   == {{"r1"}, {"r2"}, {"r1", "r2"}}
EmptyPaths == {"r1"} \ {"r1"}

VARIABLES
  (* @type: Int; *)
  now,
  (* @type: Str -> Int; *)
  offset,
  \* Authoritative remote ledger. A record exists once rAddedAt > 0 and is
  \* upstream-live until rRemovedAt > 0.
  (* @type: Str -> Str; *)
  rHolder,
  (* @type: Str -> Str; *)
  rMode,
  (* @type: Str -> Set(Str); *)
  rPaths,
  (* @type: Str -> Int; *)
  rExp,
  (* @type: Str -> Int; *)
  rSeq,
  (* @type: Str -> Int; *)
  rAddedAt,
  (* @type: Str -> Int; *)
  rRemovedAt,
  (* @type: Str -> Bool; *)
  rRevoked,
  (* @type: Int; *)
  remoteVer,
  \* Per-replica state.
  (* @type: Str -> Int; *)
  base,
  (* @type: Str -> Str; *)
  myId,
  (* @type: Str -> Str; *)
  myMode,
  (* @type: Str -> Set(Str); *)
  myPaths,
  (* @type: Str -> Int; *)
  myExp,
  (* @type: Str -> Int; *)
  mySeq,
  (* @type: Str -> Bool; *)
  established,
  (* @type: Str -> Str; *)
  csMode,
  (* @type: Str -> Set(Str); *)
  csPaths

vars == <<now, offset, rHolder, rMode, rPaths, rExp, rSeq, rAddedAt,
          rRemovedAt, rRevoked, remoteVer, base, myId, myMode, myPaths, myExp,
          mySeq, established, csMode, csPaths>>

--------------------------------------------------------------------------------
(* Clocks *)

\* @type: (Str) => Int;
View(a) == now + offset[a]

\* @type: (Str) => Bool;
OwnExpired(a) == myExp[a] <= View(a)

\* SS8.3: peers judge expiry late, with the allowance.
\* @type: (Str, Str) => Bool;
PeerExpired(a, c) == rExp[c] + SkewAllow <= View(a)

\* SS8.2: the only frame-correct ground truth for expiry is the holder's own.
\* @type: (Str) => Bool;
HolderExpired(c) ==
  IF rHolder[c] = NoneActor
  THEN TRUE
  ELSE rExp[c] <= now + offset[rHolder[c]]

--------------------------------------------------------------------------------
(* Ledger visibility *)

\* Ground truth at the remote.
\* @type: (Str) => Bool;
UpstreamLive(c) == rAddedAt[c] > 0 /\ rRemovedAt[c] = 0

\* What actor a's replica shows, given it last fetched at version base[a].
\* A removal that happened after base[a] is not yet visible to a.
\* @type: (Str, Str) => Bool;
LiveTo(a, c) ==
  /\ rAddedAt[c] > 0
  /\ rAddedAt[c] <= base[a]
  /\ (rRemovedAt[c] = 0 \/ rRemovedAt[c] > base[a])

\* SS7.1 conflict, evaluated against a's replica.
\* @type: (Str, Set(Str), Str, Str) => Bool;
BlocksLocal(a, s, m, c) ==
  /\ LiveTo(a, c)
  /\ rHolder[c] # a
  /\ ~PeerExpired(a, c)
  /\ rPaths[c] \cap s # EmptyPaths
  /\ (m = "write" \/ rMode[c] = "write")

\* @type: (Str, Set(Str), Str) => Bool;
FreeLocal(a, s, m) == \A c \in ClaimIds: ~BlocksLocal(a, s, m, c)

\* Would a's pending claim conflict against the tip it is about to rebase onto?
\* @type: (Str) => Bool;
PendingNowConflicts(a) ==
  /\ myId[a] # NoneClaim
  /\ ~established[a]
  /\ \E c \in ClaimIds:
       /\ rAddedAt[c] > 0
       /\ rRemovedAt[c] = 0
       /\ rHolder[c] # a
       /\ ~PeerExpired(a, c)
       /\ rPaths[c] \cap myPaths[a] # EmptyPaths
       /\ (myMode[a] = "write" \/ rMode[c] = "write")

--------------------------------------------------------------------------------
(* Initial state *)

TypeOK ==
  /\ RequireEstablished \in BOOLEAN
  /\ FFOnPush \in BOOLEAN
  /\ RevalidateOnRebase \in BOOLEAN
  /\ FetchBeforeFence \in BOOLEAN
  /\ AllowSteal \in BOOLEAN
  /\ now \in 0..MaxTime
  /\ offset \in [Actors \cup {NoneActor} -> Offsets]
  /\ rHolder \in [ClaimIds -> Actors \cup {NoneActor}]
  /\ rMode \in [ClaimIds -> Modes \cup {NoneMode}]
  /\ rPaths \in [ClaimIds -> SUBSET Resources]
  /\ rExp \in [ClaimIds -> -4..(MaxTime + LeaseDur + MaxSkew)]
  /\ rSeq \in [ClaimIds -> 0..(MaxVer + 2)]
  /\ rAddedAt \in [ClaimIds -> 0..MaxVer]
  /\ rRemovedAt \in [ClaimIds -> 0..MaxVer]
  /\ rRevoked \in [ClaimIds -> BOOLEAN]
  /\ remoteVer \in 0..MaxVer
  /\ base \in [Actors -> 0..MaxVer]
  /\ myId \in [Actors -> ClaimIds \cup {NoneClaim}]
  /\ myMode \in [Actors -> Modes \cup {NoneMode}]
  /\ myPaths \in [Actors -> SUBSET Resources]
  /\ myExp \in [Actors -> -4..(MaxTime + LeaseDur + MaxSkew)]
  /\ mySeq \in [Actors -> 0..(MaxVer + 2)]
  /\ established \in [Actors -> BOOLEAN]
  /\ csMode \in [Actors -> Modes \cup {NoneMode}]
  /\ csPaths \in [Actors -> SUBSET Resources]

Init ==
  /\ now = 0
  /\ offset \in [Actors \cup {NoneActor} -> Offsets]
  /\ offset[NoneActor] = 0
  /\ rHolder = [c \in ClaimIds |-> NoneActor]
  /\ rMode = [c \in ClaimIds |-> NoneMode]
  /\ rPaths = [c \in ClaimIds |-> EmptyPaths]
  /\ rExp = [c \in ClaimIds |-> 0]
  /\ rSeq = [c \in ClaimIds |-> 0]
  /\ rAddedAt = [c \in ClaimIds |-> 0]
  /\ rRemovedAt = [c \in ClaimIds |-> 0]
  /\ rRevoked = [c \in ClaimIds |-> FALSE]
  /\ remoteVer = 0
  /\ base = [a \in Actors |-> 0]
  /\ myId = [a \in Actors |-> NoneClaim]
  /\ myMode = [a \in Actors |-> NoneMode]
  /\ myPaths = [a \in Actors |-> EmptyPaths]
  /\ myExp = [a \in Actors |-> 0]
  /\ mySeq = [a \in Actors |-> 0]
  /\ established = [a \in Actors |-> FALSE]
  /\ csMode = [a \in Actors |-> NoneMode]
  /\ csPaths = [a \in Actors |-> EmptyPaths]

--------------------------------------------------------------------------------
(* Actions *)

\* SS8.5 deadline obligation is hardcoded: an in-CS actor renews or aborts
\* before its own deadline, so time may not step over it.
Tick ==
  /\ now < MaxTime
  /\ \A a \in Actors:
       csMode[a] # NoneMode => myExp[a] > now + 1 + offset[a]
  /\ now' = now + 1
  /\ UNCHANGED <<offset, rRevoked, rHolder, rMode, rPaths, rExp, rSeq, rAddedAt,
                 rRemovedAt, remoteVer, base, myId, myMode, myPaths, myExp,
                 mySeq, established, csMode, csPaths>>

\* SS11.2: fetch the remote tip, then re-derive any pending claim onto it.
\* A pending claim invalidated by the rebase aborts whatever it was gating.
Fetch ==
  \E a \in Actors:
    /\ base[a] < remoteVer
    /\ LET drop == RevalidateOnRebase /\ PendingNowConflicts(a) IN
       /\ base' = [base EXCEPT ![a] = remoteVer]
       /\ myId' = IF drop THEN [myId EXCEPT ![a] = NoneClaim] ELSE myId
       /\ myMode' = IF drop THEN [myMode EXCEPT ![a] = NoneMode] ELSE myMode
       /\ myPaths' = IF drop THEN [myPaths EXCEPT ![a] = EmptyPaths] ELSE myPaths
       /\ csMode' = IF drop THEN [csMode EXCEPT ![a] = NoneMode] ELSE csMode
       /\ csPaths' = IF drop THEN [csPaths EXCEPT ![a] = EmptyPaths] ELSE csPaths
    /\ UNCHANGED <<now, offset, rRevoked, rHolder, rMode, rPaths, rExp, rSeq, rAddedAt,
                   rRemovedAt, remoteVer, myExp, mySeq, established>>

\* SS9.1 against the local replica. Note this cannot see a peer's unpushed
\* claim, nor a peer's claim pushed after this replica's last fetch.
AcquireLocal ==
  \E a \in Actors:
    \E c \in ClaimIds:
      \E s \in PathSets:
        \E m \in Modes:
          /\ myId[a] = NoneClaim
          /\ csMode[a] = NoneMode
          /\ rAddedAt[c] = 0
          /\ \A b \in Actors: myId[b] # c
          /\ FreeLocal(a, s, m)
          /\ myId' = [myId EXCEPT ![a] = c]
          /\ myPaths' = [myPaths EXCEPT ![a] = s]
          /\ myMode' = [myMode EXCEPT ![a] = m]
          /\ myExp' = [myExp EXCEPT ![a] = View(a) + LeaseDur]
          /\ mySeq' = [mySeq EXCEPT ![a] = 1]
          /\ established' = [established EXCEPT ![a] = FALSE]
          /\ UNCHANGED <<now, offset, rRevoked, rHolder, rMode, rPaths, rExp, rSeq,
                         rAddedAt, rRemovedAt, remoteVer, base, csMode,
                         csPaths>>

\* SS7.3: the claim becomes established only when this succeeds.
Push ==
  \E a \in Actors:
    LET c == myId[a] IN
    /\ c # NoneClaim
    /\ ~established[a]
    /\ remoteVer < MaxVer
    /\ (FFOnPush => base[a] = remoteVer)
    /\ rHolder' = [rHolder EXCEPT ![c] = a]
    /\ rMode' = [rMode EXCEPT ![c] = myMode[a]]
    /\ rPaths' = [rPaths EXCEPT ![c] = myPaths[a]]
    /\ rExp' = [rExp EXCEPT ![c] = myExp[a]]
    /\ rSeq' = [rSeq EXCEPT ![c] = mySeq[a]]
    /\ rAddedAt' = [rAddedAt EXCEPT ![c] = remoteVer + 1]
    /\ remoteVer' = remoteVer + 1
    /\ base' = [base EXCEPT ![a] = remoteVer + 1]
    /\ established' = [established EXCEPT ![a] = TRUE]
    /\ UNCHANGED <<now, offset, rRevoked, rRemovedAt, myId, myMode, myPaths, myExp,
                   mySeq, csMode, csPaths>>

Renew ==
  \E a \in Actors:
    LET c == myId[a] IN
    /\ c # NoneClaim
    /\ established[a]
    /\ base[a] = remoteVer
    /\ UpstreamLive(c)
    /\ rHolder[c] = a
    /\ rSeq[c] = mySeq[a]
    /\ ~rRevoked[c]
    /\ ~OwnExpired(a)
    /\ remoteVer < MaxVer
    /\ rExp' = [rExp EXCEPT ![c] = View(a) + LeaseDur]
    /\ rSeq' = [rSeq EXCEPT ![c] = mySeq[a] + 1]
    /\ remoteVer' = remoteVer + 1
    /\ base' = [base EXCEPT ![a] = remoteVer + 1]
    /\ myExp' = [myExp EXCEPT ![a] = View(a) + LeaseDur]
    /\ mySeq' = [mySeq EXCEPT ![a] = mySeq[a] + 1]
    /\ UNCHANGED <<now, offset, rRevoked, rHolder, rMode, rPaths, rAddedAt, rRemovedAt,
                   myId, myMode, myPaths, established, csMode, csPaths>>

ReleaseEstablished ==
  \E a \in Actors:
    LET c == myId[a] IN
    /\ c # NoneClaim
    /\ established[a]
    /\ csMode[a] = NoneMode
    /\ base[a] = remoteVer
    /\ UpstreamLive(c)
    /\ rHolder[c] = a
    /\ remoteVer < MaxVer
    /\ rRemovedAt' = [rRemovedAt EXCEPT ![c] = remoteVer + 1]
    /\ remoteVer' = remoteVer + 1
    /\ base' = [base EXCEPT ![a] = remoteVer + 1]
    /\ myId' = [myId EXCEPT ![a] = NoneClaim]
    /\ myMode' = [myMode EXCEPT ![a] = NoneMode]
    /\ myPaths' = [myPaths EXCEPT ![a] = EmptyPaths]
    /\ established' = [established EXCEPT ![a] = FALSE]
    /\ UNCHANGED <<now, offset, rRevoked, rHolder, rMode, rPaths, rExp, rSeq, rAddedAt,
                   myExp, mySeq, csMode, csPaths>>

\* Abandoning a claim that was never published costs no ledger write.
ReleaseLocal ==
  \E a \in Actors:
    /\ myId[a] # NoneClaim
    /\ ~established[a]
    /\ csMode[a] = NoneMode
    /\ myId' = [myId EXCEPT ![a] = NoneClaim]
    /\ myMode' = [myMode EXCEPT ![a] = NoneMode]
    /\ myPaths' = [myPaths EXCEPT ![a] = EmptyPaths]
    /\ UNCHANGED <<now, offset, rRevoked, rHolder, rMode, rPaths, rExp, rSeq, rAddedAt,
                   rRemovedAt, remoteVer, base, myExp, mySeq, established,
                   csMode, csPaths>>

\* SS6 deletion case (b): reaping an expired peer claim.
Reap ==
  \E a \in Actors:
    \E c \in ClaimIds:
      /\ UpstreamLive(c)
      /\ rHolder[c] # a
      /\ base[a] = remoteVer
      /\ PeerExpired(a, c)
      /\ remoteVer < MaxVer
      /\ rRemovedAt' = [rRemovedAt EXCEPT ![c] = remoteVer + 1]
      /\ remoteVer' = remoteVer + 1
      /\ base' = [base EXCEPT ![a] = remoteVer + 1]
      /\ UNCHANGED <<now, offset, rRevoked, rHolder, rMode, rPaths, rExp, rSeq, rAddedAt,
                     myId, myMode, myPaths, myExp, mySeq, established, csMode,
                     csPaths>>

\* SS6 deletion case (c), unsafe form: delete a live claim immediately. This
\* is what the specification described before the model refuted it.
StealRemove ==
  \E a \in Actors:
    \E c \in ClaimIds:
      /\ AllowSteal
      /\ ~SafeSteal
      /\ UpstreamLive(c)
      /\ rHolder[c] # a
      /\ base[a] = remoteVer
      /\ remoteVer < MaxVer
      /\ rRemovedAt' = [rRemovedAt EXCEPT ![c] = remoteVer + 1]
      /\ remoteVer' = remoteVer + 1
      /\ base' = [base EXCEPT ![a] = remoteVer + 1]
      /\ UNCHANGED <<now, offset, rRevoked, rHolder, rMode, rPaths, rExp, rSeq,
                     rAddedAt, myId, myMode, myPaths, myExp, mySeq, established,
                     csMode, csPaths>>

\* SS6 deletion case (c), safe form: revoke the claim so it cannot be renewed,
\* and let it fall out through the ordinary expiry path. The exclusion window
\* is never shortened below the victim's own deadline, so the victim's SS8.5
\* obligation guarantees it has stopped before anyone else can acquire.
StealRevoke ==
  \E a \in Actors:
    \E c \in ClaimIds:
      /\ AllowSteal
      /\ SafeSteal
      /\ UpstreamLive(c)
      /\ ~rRevoked[c]
      /\ rHolder[c] # a
      /\ base[a] = remoteVer
      /\ remoteVer < MaxVer
      /\ rRevoked' = [rRevoked EXCEPT ![c] = TRUE]
      /\ remoteVer' = remoteVer + 1
      /\ base' = [base EXCEPT ![a] = remoteVer + 1]
      /\ UNCHANGED <<now, offset, rHolder, rMode, rPaths, rExp, rSeq, rAddedAt,
                     rRemovedAt, myId, myMode, myPaths, myExp, mySeq,
                     established, csMode, csPaths>>

\* SS8.4 fence, read against this replica's view of the ledger.
EnterCS ==
  \E a \in Actors:
    LET c == myId[a] IN
    /\ c # NoneClaim
    /\ csMode[a] = NoneMode
    /\ ~OwnExpired(a)
    /\ (RequireEstablished => established[a])
    /\ (FetchBeforeFence => base[a] = remoteVer)
    /\ (established[a] =>
          /\ LiveTo(a, c)
          /\ rHolder[c] = a
          /\ rSeq[c] = mySeq[a])
    /\ csMode' = [csMode EXCEPT ![a] = myMode[a]]
    /\ csPaths' = [csPaths EXCEPT ![a] = myPaths[a]]
    /\ UNCHANGED <<now, offset, rRevoked, rHolder, rMode, rPaths, rExp, rSeq, rAddedAt,
                   rRemovedAt, remoteVer, base, myId, myMode, myPaths, myExp,
                   mySeq, established>>

ExitCS ==
  \E a \in Actors:
    /\ csMode[a] # NoneMode
    /\ csMode' = [csMode EXCEPT ![a] = NoneMode]
    /\ csPaths' = [csPaths EXCEPT ![a] = EmptyPaths]
    /\ UNCHANGED <<now, offset, rRevoked, rHolder, rMode, rPaths, rExp, rSeq, rAddedAt,
                   rRemovedAt, remoteVer, base, myId, myMode, myPaths, myExp,
                   mySeq, established>>

Idle ==
  /\ now = MaxTime
  /\ remoteVer = MaxVer
  /\ UNCHANGED vars

Next ==
  \/ Tick
  \/ Fetch
  \/ AcquireLocal
  \/ Push
  \/ Renew
  \/ ReleaseEstablished
  \/ ReleaseLocal
  \/ Reap
  \/ StealRemove
  \/ StealRevoke
  \/ EnterCS
  \/ ExitCS
  \/ Idle

Spec == Init /\ [][Next]_vars

--------------------------------------------------------------------------------
(* Properties *)

MutualExclusion ==
  \A a \in Actors:
    \A b \in Actors:
      (/\ a # b
       /\ csMode[a] # NoneMode
       /\ csMode[b] # NoneMode
       /\ csPaths[a] \cap csPaths[b] # EmptyPaths)
      => (csMode[a] = "read" /\ csMode[b] = "read")

\* SS7.2 at the remote: the authoritative ledger must never hold two live
\* conflicting claims, however stale the replicas that produced them were.
RemoteConflictFree ==
  \A c \in ClaimIds:
    \A d \in ClaimIds:
      (/\ c # d
       /\ UpstreamLive(c)
       /\ UpstreamLive(d)
       /\ rHolder[c] # rHolder[d]
       /\ ~HolderExpired(c)
       /\ ~HolderExpired(d)
       /\ rPaths[c] \cap rPaths[d] # EmptyPaths)
      => (rMode[c] = "read" /\ rMode[d] = "read")

\* SS7.3: "locally held but not globally established" must not be mistaken for
\* a lock. An actor in a gated operation owns a live, published, matching lease.
CSLeaseValid ==
  \A a \in Actors:
    csMode[a] # NoneMode =>
      (/\ myId[a] # NoneClaim
       /\ established[a]
       /\ UpstreamLive(myId[a])
       /\ rHolder[myId[a]] = a
       /\ rSeq[myId[a]] = mySeq[a]
       /\ ~OwnExpired(a))

\* An established claim's local record agrees with the published one.
EstablishedMatchesRemote ==
  \A a \in Actors:
    (established[a] /\ myId[a] # NoneClaim /\ UpstreamLive(myId[a]))
      => (/\ rHolder[myId[a]] = a
          /\ rPaths[myId[a]] = myPaths[a]
          /\ rMode[myId[a]] = myMode[a])

(* Vacuity witnesses. These are EXPECTED TO BE VIOLATED: a counterexample is
   proof that the model can actually reach the state in question, so that a
   NoError result on the safety invariants is meaningful rather than trivial. *)

\* Can an actor ever hold an established claim and enter a gated operation?
WitnessEstablishedCS ==
  \A a \in Actors: ~(csMode[a] # NoneMode /\ established[a])

\* Can two actors ever hold published claims at the same time?
WitnessTwoEstablished ==
  ~(\E a \in Actors: \E b \in Actors:
      a # b /\ established[a] /\ established[b])

\* Can a replica ever fall behind the remote, i.e. does staleness occur?
WitnessStaleReplica ==
  \A a \in Actors: base[a] = remoteVer

\* Can a rebase ever actually invalidate a pending claim?
WitnessRebaseDrop ==
  \A a \in Actors: ~PendingNowConflicts(a)

Safety ==
  /\ MutualExclusion
  /\ RemoteConflictFree
  /\ CSLeaseValid
  /\ EstablishedMatchesRemote

================================================================================
