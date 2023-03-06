import Duper.MClause
import Duper.RuleM
import Duper.Simp
import Duper.Util.ProofReconstruction

namespace Duper
open Lean
open RuleM
open SimpResult

initialize Lean.registerTraceClass `Rule.forallHoist

theorem forall_hoist_proof {y : α → Prop} (x : α) (f : Prop → Prop) (h : f (∀ z : α, y z)) : f False ∨ y x = True := by
  by_cases y_always_true : ∀ z : α, y z
  . exact Or.inr (eq_true (y_always_true x))
  . rename ¬∀ (z : α), y z => y_not_always_true
    exact Or.inl (eq_false y_not_always_true ▸ h)

def mkForallHoistProof (pos : ClausePos) (premises : List Expr)
  (parents : List ProofParent) (transferExprs : Array Expr) (c : Clause) : MetaM Expr :=
  Meta.forallTelescope c.toForallExpr fun xs body => do
    let cLits := c.lits.map (fun l => l.map (fun e => e.instantiateRev xs))
    let (parentsLits, appliedPremises, transferExprs) ← instantiatePremises parents premises xs transferExprs
    let parentLits := parentsLits[0]!
    let appliedPremise := appliedPremises[0]!

    let #[freshVar1] := transferExprs
      | throwError "mkForallHoistProof :: Wrong number of number of newVarIndices"

    let mut caseProofs := Array.mkEmpty parentLits.size
    for i in [:parentLits.size] do
      let lit := parentLits[i]!
      let pr : Expr ← Meta.withLocalDeclD `h lit.toExpr fun h => do
        if i == pos.lit then
          let substLitPos : LitPos := ⟨pos.side, pos.pos⟩
          let abstrLit ← (lit.abstractAtPos! substLitPos)
          let abstrExp := abstrLit.toExpr
          let abstrLam := mkLambda `x BinderInfo.default (mkSort levelZero) abstrExp
          let lastTwoLitsProof ← Meta.mkAppM ``forall_hoist_proof #[freshVar1, abstrLam, h]
          Meta.mkLambdaFVars #[h] $ ← orSubclause (cLits.map Lit.toExpr) 2 lastTwoLitsProof
        else
          let idx := if i ≥ pos.lit then i - 1 else i
          Meta.mkLambdaFVars #[h] $ ← orIntro (cLits.map Lit.toExpr) idx h
      caseProofs := caseProofs.push pr
    let r ← orCases (parentLits.map Lit.toExpr) caseProofs
    Meta.mkLambdaFVars xs $ mkApp r appliedPremise

/-- Returns the dependent forall and lambda expressions -/
def mkForallAndLambda (freshVar1Ty : Expr) : MetaM (Expr × Expr) :=
  Meta.withLocalDeclD `_ freshVar1Ty fun fvar => do
    let newMVar ← Meta.mkFreshExprMVar (mkSort levelZero)
    let forallExpr ← Meta.mkForallFVars #[fvar] newMVar
    let lambdaExpr ← Meta.mkLambdaFVars #[fvar] newMVar
    return (forallExpr, lambdaExpr)

def forallHoistAtExpr (e : Expr) (pos : ClausePos) (given : Clause) (c : MClause) : RuleM (Array ClauseStream) :=
  withoutModifyingMCtx do
    let lit := c.lits[pos.lit]!
    if e.getTopSymbol.isMVar then -- Check condition 4
      -- If the head of e is a variable then it must be applied and the affected literal must be either
      -- e = True, e = False, or e = e' where e' is another variable headed term
      if not e.isApp then -- e is a non-applied variable and so we cannot apply neHoist
        return #[]
      if pos.pos != #[] then
        return #[] -- e is not at the top level so the affected literal cannot have the form e = ...
      if not lit.sign then
        return #[] -- The affected literal is not positive and so it cannot have the form e = ...
      let otherSide := lit.getOtherSide pos.side
      if otherSide != (mkConst ``True) && otherSide != (mkConst ``False) && not otherSide.getTopSymbol.isMVar then
        return #[] -- The other side is not True, False, or variable headed, so the affected literal cannot have the required form
    -- Check conditions 1 and 3 (condition 2 is guaranteed by construction)
    let eligibility ← eligibilityPreUnificationCheck c pos.lit
    if eligibility == Eligibility.notEligible then
      return #[]
    let freshVar1 ← mkFreshExprMVar none
    let freshVar1Ty ← inferType freshVar1
    let (freshVarForallExpr, freshVarLambdaExpr) ← runMetaAsRuleM $ mkForallAndLambda freshVar1Ty
    let newLitLhs ← runMetaAsRuleM $ Meta.whnf (.app freshVarLambdaExpr freshVar1)
    -- Perform unification
    let ug ← unifierGenerator #[(e, freshVarForallExpr)]
    let loaded ← getLoadedClauses
    let yC := do
      setLoadedClauses loaded
      if not $ ← eligibilityPostUnificationCheck c pos.lit eligibility (strict := lit.sign) then
        return none
      let eSide ← RuleM.instantiateMVars $ lit.getSide pos.side
      let otherSide ← RuleM.instantiateMVars $ lit.getOtherSide pos.side
      let cmp ← compare eSide otherSide
      if cmp == Comparison.LessThan || cmp == Comparison.Equal then -- If eSide ≤ otherSide then e is not in an eligible position
        return none
      -- All side conditions have been met. Yield the appropriate clause
      let cErased := c.eraseLit pos.lit
      -- Need to instantiate mvars in freshVar1, freshVar2, and newLit because unification assigned to mvars in each of them
      let newLitLhs ← RuleM.instantiateMVars newLitLhs
      let newLitLhs ← RuleM.runMetaAsRuleM $ Meta.whnf newLitLhs -- newLitLhs probably has the form (λ x, stuff) x, so perform the application
      let newClause := cErased.appendLits #[← lit.replaceAtPos! ⟨pos.side, pos.pos⟩ (mkConst ``False), Lit.fromSingleExpr newLitLhs (sign := true)]
      trace[Rule.forallHoist] "Created {newClause.lits} from {c.lits}"
      yieldClause newClause "forallHoist" (some (mkForallHoistProof pos)) (transferExprs := #[freshVar1])
    return #[⟨ug, given, yC⟩]

def forallHoist (given : Clause) (c : MClause) (cNum : Nat) : RuleM (Array ClauseStream) := do
  let fold_fn := fun streams e pos => do
    let str ← forallHoistAtExpr e.consumeMData pos given c
    return streams.append str
  c.foldGreenM fold_fn #[]