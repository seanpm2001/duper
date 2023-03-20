import Lean
open Lean

def List.subsequences (xs : List α) :=
  match xs with
  | nil => [nil]
  | cons a as => List.subsequences as ++ map (List.cons a) (List.subsequences as)

-- The following two functions are copied from Lean's
-- standard library. The only difference is that we
-- replace `whnf e` with `e`.
private partial def instantiateForallAux (ps : Array Expr) (i : Nat) (e : Expr) : MetaM Expr := do
  if h : i < ps.size then
    let p := ps.get ⟨i, h⟩
    match e with
    | Expr.forallE _ _ b _ => instantiateForallAux ps (i+1) (b.instantiate1 p)
    | _                => throwError "invalid instantiateForallNoReducing, too many parameters"
  else
    return e

private partial def instantiateForallAuxNoError (ps : Array Expr) (i : Nat) (e : Expr) : Expr :=
  if h : i < ps.size then
    let p := ps.get ⟨i, h⟩
    match e with
    | Expr.forallE _ _ b _ => instantiateForallAuxNoError ps (i+1) (b.instantiate1 p)
    | _ => panic! "Called instantiateForallAuxNoError with too many parameters"
  else e

def Lean.getParamLevelName! : Level → Name
| .param name => name
| e           => panic! s!"Lean.getLevelParamName! :: Level {e} is not a parameter level."

def Lean.Expr.countLambdas : Expr → Nat
| lam _ _ b _  => countLambdas b + 1
| _            => 0

def Lean.Expr.countForalls : Expr → Nat
| forallE _ _ b _ => countForalls b + 1
| _               => 0

/-- Given `e` of the form `forall (a_1 : A_1) ... (a_n : A_n), B[a_1, ..., a_n]` and `p_1 : A_1, ... p_n : A_n`, return `B[p_1, ..., p_n]`. -/
def Lean.Expr.instantiateForallNoReducing (e : Expr) (ps : Array Expr) : MetaM Expr :=
  instantiateForallAux ps 0 e

def Lean.Expr.instantiateForallNoReducingNoError (e : Expr) (ps : Array Expr) : Expr :=
  instantiateForallAuxNoError ps 0 e

def Lean.Meta.withoutMVarAssignments (m : MetaM α) : MetaM α := do
  let mctx ← getMCtx
  Meta.withMCtx {mctx with eAssignment := {}, lAssignment := {}} m

initialize Lean.registerTraceClass `Meta.inspectMVarAssignments

def Lean.Meta.inspectMVarAssignments : MetaM Unit := do
  let mctx ← getMCtx
  let eAssignmentList := mctx.eAssignment.toList
  let lAssignmentList := mctx.lAssignment.toList
  Meta.withMCtx {mctx with eAssignment := {}, lAssignment := {}} <| do
    let ems := eAssignmentList.map (fun (id, e) => MessageData.compose m!"{Expr.mvar id} := " m!"{e}")
    let lms := lAssignmentList.map (fun (id, l) => MessageData.compose m!"{Level.mvar id} := " m!"{l}")
    let mut em := m!"["; let mut fst := true
    for m in ems do
      if fst then
        fst := false
      else
        em := .compose em m!", "
      em := .compose em m
    em := .compose em "]"
    trace[Meta.inspectMVarAssignments] .compose "ExprMVar Assignments: " em
    let mut lm := m!"["; fst := true
    for m in lms do
      if fst then
        fst := false
      else
        lm := .compose lm m!", "
      lm := .compose lm m
    lm := .compose lm "]"
    trace[Meta.inspectMVarAssignments] .compose "LevelMVar Assignments: " lm

noncomputable def getInstanceFromLeftNonemptyFact (nonemptyFact : Nonempty t = True) : t :=
  Classical.choice $ of_eq_true nonemptyFact

noncomputable def getInstanceFromRightNonemptyFact (nonemptyFact : True = Nonempty t) : t :=
  Classical.choice $ of_eq_true (Eq.symm nonemptyFact)

def getInstanceFromNonemptyFact (nonemptyFact : Expr) : MetaM Expr := do
  try Meta.mkAppM ``getInstanceFromLeftNonemptyFact #[nonemptyFact]
  catch _ => Meta.mkAppM ``getInstanceFromRightNonemptyFact #[nonemptyFact]

def Lean.Meta.findInstance (ty : Expr) (nonemptyFacts : List Expr := []) : MetaM Expr := do
  let ty ← instantiateMVars ty
  forallTelescope ty fun xs ty' => do
    let u ← do
      if ty' == .sort (.succ .zero) then
        pure <| mkConst ``Nat
      else if let .sort (.succ l) := ty then
        pure <| mkSort l
      else try
        Meta.mkAppOptM ``inferInstanceAs #[ty', none]
      catch _ =>
        -- Find assumption in Local Context
        let ctx ← getLCtx
        let option_matching_expr ← ctx.findDeclM? fun decl : Lean.LocalDecl => do
          let declExpr := decl.toExpr
          let declType ← Lean.Meta.inferType declExpr
          if ← Lean.Meta.isDefEq declType ty'
          then
            return Option.some declExpr
          else
            return Option.none
        match option_matching_expr with
        | some e => pure e
        | none =>
          try Meta.mkAppOptM ``default #[ty', none]
          catch _ => do
            for nonemptyFact in nonemptyFacts do
              trace[typeInhabitationReasoning.debug] "About to get inst from nonemptyFact: {nonemptyFact}"
              let inst ← getInstanceFromNonemptyFact nonemptyFact
              if (← inferType inst) == ty' then return inst
            trace[typeInhabitationReasoning.debug] "nonemptyFacts: {nonemptyFacts}"
            throwError "Failed to find an instance for type {ty}"
    mkLambdaFVars xs u

def Lean.Meta.tryFindInstance (ty : Expr) : MetaM (Option Expr) :=
  try Lean.Meta.findInstance ty
  catch _ => return none

/-- Returns the arity of e -/
partial def getArity (e : Expr) : Nat :=
  match e.consumeMData with
  | Expr.forallE _ _ b _ => 1 + getArity b
  | _ => 0

/-- Abstracts occurences of `p` in `e`. Previously, `Meta.kabstract` was used for this purpose, but because
    `Meta.kabstract` invokes definitional equality, there were some instances in which `Meta.kabstract` performed
    an abstraction at a position where `RuleM.replace` would not perform a replacement. This was an issue because it
    created inconsistencies between the clauses produced by superposition's main code and proof reconstruction.
    
    `abstractAtExpr` is written to follow the implementation of `Meta.kabstract` without invoking definitional equality
    (instead testing for equality after instantiating metavariables).  -/
def Lean.Meta.abstractAtExpr (e : Expr) (p : Expr) (occs : Occurrences := .all) : MetaM Expr := do
  let e ← Lean.instantiateMVars e
  let p ← Lean.instantiateMVars p
  if p.isFVar && occs == Occurrences.all then
    return e.abstract #[p] -- Easy case
  else
    let pHeadIdx := p.toHeadIndex
    let pNumArgs := p.headNumArgs
    let rec visit (e : Expr) (offset : Nat) : StateRefT Nat MetaM Expr := do
      let visitChildren : Unit → StateRefT Nat MetaM Expr := fun _ => do
        match e with
        | .app f a         => return e.updateApp! (← visit f offset) (← visit a offset)
        | .mdata _ b       => return e.updateMData! (← visit b offset)
        | .proj _ _ b      => return e.updateProj! (← visit b offset)
        | .letE _ t v b _  => return e.updateLet! (← visit t offset) (← visit v offset) (← visit b (offset+1))
        | .lam _ d b _     => return e.updateLambdaE! (← visit d offset) (← visit b (offset+1))
        | .forallE _ d b _ => return e.updateForallE! (← visit d offset) (← visit b (offset+1))
        | e                => return e
      if e.hasLooseBVars then
        visitChildren ()
      else if e.toHeadIndex != pHeadIdx || e.headNumArgs != pNumArgs then
        visitChildren ()
      else if e == p then -- e and p have already had their metavariables instantiated at the beginning of abstrAtExpr
        let i ← get
        set (i+1)
        if occs.contains i then
          return mkBVar offset
        else
          visitChildren ()
      else
        visitChildren ()
    visit e 0 |>.run' 1