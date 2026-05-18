----------------------------- MODULE GitHubLiveSync -----------------------------
EXTENDS Integers, FiniteSets

(*
This is a bounded Apalache model for the Gitomi <-> GitHub live-sync identity
protocol. It intentionally abstracts away event payload reducers and models only
the parts that decide whether replicas converge on the same native Gitomi object
and the same GitHub issue/pull identity.

The important knobs are constants:

  DeterministicImports:
    TRUE  => a GitHub number imported without a known alias always chooses the
             canonical Gitomi object for that upstream item.
    FALSE => two offline/downstream-only importers may allocate different native
             Gitomi objects for the same GitHub number.

  UseExportClaim:
    TRUE  => creating a new GitHub number for a Gitomi item requires a shared
             remote claim, modeling a fast-forward/CAS lease.
    FALSE => two upstream-only exporters may create duplicate GitHub numbers.

  RequireGithubEmptyBeforeCreate:
    TRUE  => an exporter must observe that GitHub has no number for the item
             before creating one.
    FALSE => upstream-only exporters may create a GitHub duplicate for an item
             that already exists on GitHub but has not yet been imported.
*)

CONSTANTS
  (* @type: Bool; *)
  DeterministicImports,
  (* @type: Bool; *)
  UseExportClaim,
  (* @type: Bool; *)
  RequireGithubEmptyBeforeCreate,
  (* @type: Int; *)
  MaxSettleSweeps

Users == {"alice", "bob"}
Items == {"itemA", "itemB"}
Objects == {"objA0", "objA1", "objB0", "objB1"}
Numbers == {"gh1", "gh2"}
Modes == {"full", "downstream", "upstream", "offline"}

NoneObj == "NoneObj"
NoneItem == "NoneItem"
NoneUser == "NoneUser"

ObjItem(o) ==
  IF o \in {"objA0", "objA1"} THEN "itemA" ELSE "itemB"

CanonicalObject(i) ==
  IF i = "itemA" THEN "objA0" ELSE "objB0"

CanonicalNumber(i) ==
  IF i = "itemA" THEN "gh1" ELSE "gh2"

ObjectsForItem(i) == {o \in Objects: ObjItem(o) = i}

VARIABLES
  (* @type: Str; *)
  phase,
  (* @type: Int; *)
  sweeps,
  (* @type: Str -> Str; *)
  mode,
  (* @type: Str -> Set(Str); *)
  localObjs,
  (* @type: Set(Str); *)
  remoteObjs,
  (* @type: Str -> Str; *)
  ghItems,
  (* @type: Str -> (Str -> Str); *)
  localAlias,
  (* @type: Str -> Str; *)
  remoteAlias,
  (* @type: Str -> Str; *)
  claims

vars == <<phase, sweeps, mode, localObjs, remoteObjs, ghItems, localAlias, remoteAlias, claims>>

EmptyAlias == [n \in Numbers |-> NoneObj]
EmptyGithub == [n \in Numbers |-> NoneItem]
EmptyClaims == [i \in Items |-> NoneUser]

TypeOK ==
  /\ DeterministicImports \in BOOLEAN
  /\ UseExportClaim \in BOOLEAN
  /\ RequireGithubEmptyBeforeCreate \in BOOLEAN
  /\ MaxSettleSweeps \in Nat
  /\ phase \in {"active", "settle", "done"}
  /\ sweeps \in 0..MaxSettleSweeps
  /\ mode \in [Users -> Modes]
  /\ localObjs \in [Users -> SUBSET Objects]
  /\ remoteObjs \in SUBSET Objects
  /\ ghItems \in [Numbers -> (Items \cup {NoneItem})]
  /\ localAlias \in [Users -> [Numbers -> (Objects \cup {NoneObj})]]
  /\ remoteAlias \in [Numbers -> (Objects \cup {NoneObj})]
  /\ claims \in [Items -> (Users \cup {NoneUser})]

Init ==
  /\ phase = "active"
  /\ sweeps = 0
  /\ mode = [u \in Users |-> "full"]
  /\ localObjs = [u \in Users |-> {}]
  /\ remoteObjs = {}
  /\ ghItems = EmptyGithub
  /\ localAlias = [u \in Users |-> EmptyAlias]
  /\ remoteAlias = EmptyAlias
  /\ claims = EmptyClaims

CanDown(u) == mode[u] \in {"full", "downstream"}
CanUp(u) == mode[u] \in {"full", "upstream"}

HasGithubItem(g, i) == \E n \in Numbers: g[n] = i

NoLocalAliasForObject(a, o) == \A n \in Numbers: a[n] # o

AliasCompatible(a, b) ==
  \A n \in Numbers:
    \/ a[n] = NoneObj
    \/ b[n] = NoneObj
    \/ a[n] = b[n]

MergeAlias(a, b) ==
  [n \in Numbers |-> IF a[n] # NoneObj THEN a[n] ELSE b[n]]

AllLocalObjects == UNION {localObjs[u]: u \in Users}
AllAliasObjects == {localAlias[u][n]: u \in Users, n \in Numbers} \ {NoneObj}
AllRemoteAliasObjects == {remoteAlias[n]: n \in Numbers} \ {NoneObj}
AllKnownObjects == remoteObjs \cup AllLocalObjects \cup AllAliasObjects \cup AllRemoteAliasObjects
AllGithubItems == {ghItems[n]: n \in Numbers} \ {NoneItem}
AllKnownItems == {ObjItem(o): o \in AllKnownObjects} \cup AllGithubItems

ModeChange ==
  /\ phase = "active"
  /\ \E u \in Users:
       \E m \in Modes:
         /\ mode' = [mode EXCEPT ![u] = m]
         /\ UNCHANGED <<phase, sweeps, localObjs, remoteObjs, ghItems, localAlias, remoteAlias, claims>>

LocalCreate ==
  /\ phase = "active"
  /\ \E u \in Users:
       \E i \in Items:
         LET o == CanonicalObject(i) IN
         /\ mode[u] # "offline"
         /\ o \notin localObjs[u]
         /\ localObjs' = [localObjs EXCEPT ![u] = @ \cup {o}]
         /\ UNCHANGED <<phase, sweeps, mode, remoteObjs, ghItems, localAlias, remoteAlias, claims>>

GithubExternalCreate ==
  /\ phase = "active"
  /\ \E i \in Items:
       LET n == CanonicalNumber(i) IN
       /\ ghItems[n] = NoneItem
       /\ ghItems' = [ghItems EXCEPT ![n] = i]
       /\ UNCHANGED <<phase, sweeps, mode, localObjs, remoteObjs, localAlias, remoteAlias, claims>>

FetchGitomi ==
  \E u \in Users:
    /\ phase \in {"active", "settle"}
    /\ CanDown(u)
    /\ AliasCompatible(localAlias[u], remoteAlias)
    /\ localObjs' = [localObjs EXCEPT ![u] = @ \cup remoteObjs]
    /\ localAlias' = [localAlias EXCEPT ![u] = MergeAlias(@, remoteAlias)]
    /\ UNCHANGED <<phase, sweeps, mode, remoteObjs, ghItems, remoteAlias, claims>>

PushGitomi ==
  \E u \in Users:
    /\ phase \in {"active", "settle"}
    /\ CanUp(u)
    /\ AliasCompatible(remoteAlias, localAlias[u])
    /\ remoteObjs' = remoteObjs \cup localObjs[u]
    /\ remoteAlias' = MergeAlias(remoteAlias, localAlias[u])
    /\ UNCHANGED <<phase, sweeps, mode, localObjs, ghItems, localAlias, claims>>

ImportKnownAlias ==
  \E u \in Users:
    \E n \in Numbers:
      LET o == localAlias[u][n] IN
      /\ phase \in {"active", "settle"}
      /\ CanDown(u)
      /\ ghItems[n] # NoneItem
      /\ o # NoneObj
      /\ ObjItem(o) = ghItems[n]
      /\ localObjs' = [localObjs EXCEPT ![u] = @ \cup {o}]
      /\ UNCHANGED <<phase, sweeps, mode, remoteObjs, ghItems, localAlias, remoteAlias, claims>>

ImportUnknownAlias ==
  \E u \in Users:
    \E n \in Numbers:
      \E o \in ObjectsForItem(ghItems[n]):
        /\ phase \in {"active", "settle"}
        /\ CanDown(u)
        /\ ghItems[n] # NoneItem
        /\ localAlias[u][n] = NoneObj
        /\ (DeterministicImports => o = CanonicalObject(ghItems[n]))
        /\ localObjs' = [localObjs EXCEPT ![u] = @ \cup {o}]
        /\ localAlias' = [localAlias EXCEPT ![u][n] = o]
        /\ UNCHANGED <<phase, sweeps, mode, remoteObjs, ghItems, remoteAlias, claims>>

AcquireExportClaim ==
  \E u \in Users:
    \E o \in localObjs[u]:
      LET i == ObjItem(o) IN
      /\ phase = "active"
      /\ CanUp(u)
      /\ claims[i] = NoneUser
      /\ claims' = [claims EXCEPT ![i] = u]
      /\ UNCHANGED <<phase, sweeps, mode, localObjs, remoteObjs, ghItems, localAlias, remoteAlias>>

ExportCreateGithub ==
  \E u \in Users:
    \E o \in localObjs[u]:
      \E n \in Numbers:
        LET i == ObjItem(o) IN
        /\ phase \in {"active", "settle"}
        /\ CanUp(u)
        /\ NoLocalAliasForObject(localAlias[u], o)
        /\ ghItems[n] = NoneItem
        /\ (UseExportClaim => claims[i] = u)
        /\ (RequireGithubEmptyBeforeCreate => ~HasGithubItem(ghItems, i))
        /\ (RequireGithubEmptyBeforeCreate => n = CanonicalNumber(i))
        /\ ghItems' = [ghItems EXCEPT ![n] = i]
        /\ localAlias' = [localAlias EXCEPT ![u][n] = o]
        /\ UNCHANGED <<phase, sweeps, mode, localObjs, remoteObjs, remoteAlias, claims>>

StartSettle ==
  /\ phase = "active"
  /\ phase' = "settle"
  /\ sweeps' = 0
  /\ mode' = [u \in Users |-> "full"]
  /\ UNCHANGED <<localObjs, remoteObjs, ghItems, localAlias, remoteAlias, claims>>

SettleGithubItems ==
  [n \in Numbers |->
    IF ghItems[n] # NoneItem THEN
      ghItems[n]
    ELSE
      IF \E i \in AllKnownItems: CanonicalNumber(i) = n THEN
        CHOOSE i \in AllKnownItems: CanonicalNumber(i) = n
      ELSE
        NoneItem]

SettleAliases(g) ==
  [n \in Numbers |-> IF g[n] = NoneItem THEN NoneObj ELSE CanonicalObject(g[n])]

SettleObjects(items) == {CanonicalObject(i): i \in items}

SettleSweep ==
  /\ phase = "settle"
  /\ sweeps < MaxSettleSweeps
  /\ LET g == SettleGithubItems IN
     LET aliases == SettleAliases(g) IN
     LET objs == SettleObjects({g[n]: n \in Numbers} \ {NoneItem}) IN
       /\ ghItems' = g
       /\ remoteAlias' = aliases
       /\ localAlias' = [u \in Users |-> aliases]
       /\ remoteObjs' = objs
       /\ localObjs' = [u \in Users |-> objs]
       /\ sweeps' = sweeps + 1
       /\ UNCHANGED <<phase, mode, claims>>

Converged ==
  /\ \A u \in Users: localObjs[u] = remoteObjs
  /\ \A u \in Users: localAlias[u] = remoteAlias
  /\ \A n \in Numbers: ghItems[n] # NoneItem => remoteAlias[n] # NoneObj
  /\ \A n \in Numbers: remoteAlias[n] # NoneObj => ghItems[n] = ObjItem(remoteAlias[n])

FinishSettle ==
  /\ phase = "settle"
  /\ Converged
  /\ phase' = "done"
  /\ UNCHANGED <<sweeps, mode, localObjs, remoteObjs, ghItems, localAlias, remoteAlias, claims>>

DoneStutter ==
  /\ phase = "done"
  /\ UNCHANGED vars

Next ==
  \/ ModeChange
  \/ LocalCreate
  \/ GithubExternalCreate
  \/ FetchGitomi
  \/ PushGitomi
  \/ ImportKnownAlias
  \/ ImportUnknownAlias
  \/ AcquireExportClaim
  \/ ExportCreateGithub
  \/ StartSettle
  \/ SettleSweep
  \/ FinishSettle
  \/ DoneStutter

Spec == Init /\ [][Next]_vars

AliasSound ==
  /\ \A n \in Numbers:
       remoteAlias[n] # NoneObj => ghItems[n] = ObjItem(remoteAlias[n])
  /\ \A u \in Users:
       \A n \in Numbers:
         localAlias[u][n] # NoneObj => ghItems[n] = ObjItem(localAlias[u][n])

OneGithubNumberPerItem ==
  \A i \in Items:
    Cardinality({n \in Numbers: ghItems[n] = i}) <= 1

NoDuplicateGitomiObjectsPerItem ==
  \A i \in Items:
    Cardinality({o \in AllKnownObjects: ObjItem(o) = i}) <= 1

Safety ==
  /\ AliasSound
  /\ OneGithubNumberPerItem
  /\ NoDuplicateGitomiObjectsPerItem

ConvergenceAfterSettle ==
  phase = "settle" /\ sweeps = MaxSettleSweeps => Converged

================================================================================
