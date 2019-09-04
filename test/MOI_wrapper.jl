using GLPK, Test

const MOI  = GLPK.MathOptInterface
const MOIT = MOI.Test

const OPTIMIZER = MOI.Bridges.full_bridge_optimizer(
    GLPK.Optimizer(), Float64
)
const CONFIG = MOIT.TestConfig()

@testset "Unit Tests" begin
    MOIT.basic_constraint_tests(OPTIMIZER, CONFIG)
    MOIT.unittest(OPTIMIZER, CONFIG, [
        # These are excluded because GLPK does not support quadratics.
        "solve_qp_edge_cases", "solve_qcp_edge_cases",
        "solve_zero_one_with_bounds_3"
    ])
    @testset "solve_zero_one_with_bounds_3" begin
        MOI.empty!(OPTIMIZER)
        MOI.Utilities.loadfromstring!(OPTIMIZER,"""
            variables: x
            maxobjective: 2.0x
            c1: x in ZeroOne()
            c2: x >= 0.2
            c3: x <= 0.5
        """)
        MOI.optimize!(OPTIMIZER)
        # We test this here because the TerminationStatus is INVALID_MODEL not
        # INFEASIBLE.
        @test MOI.get(OPTIMIZER, MOI.TerminationStatus()) == MOI.INVALID_MODEL
    end
    MOIT.modificationtest(OPTIMIZER, CONFIG)
end

@testset "Linear tests" begin
@testset "Default Solver"  begin
        MOIT.contlineartest(OPTIMIZER, MOIT.TestConfig(basis = true), [
            # This requires an infeasiblity certificate for a variable bound.
            "linear12",
            # VariablePrimalStart not supported.
            "partial_start"
        ])
    end
    @testset "No certificate" begin
        MOIT.linear12test(OPTIMIZER, MOIT.TestConfig(infeas_certificates=false))
    end
end

@testset "Linear Conic tests" begin
    MOIT.lintest(OPTIMIZER, CONFIG)
end

@testset "Integer Linear tests" begin
    MOIT.intlineartest(OPTIMIZER, CONFIG, [
        "int2", "indicator1", "indicator2", "indicator3"
    ])
end

@testset "ModelLike tests" begin
    @test MOI.get(OPTIMIZER, MOI.SolverName()) == "GLPK"

    @testset "default_objective_test" begin
        MOIT.default_objective_test(OPTIMIZER)
    end

    @testset "default_status_test" begin
        MOIT.default_status_test(OPTIMIZER)
    end

    @testset "nametest" begin
        MOIT.nametest(OPTIMIZER)
    end

    @testset "validtest" begin
        MOIT.validtest(OPTIMIZER)
    end

    @testset "emptytest" begin
        MOIT.emptytest(OPTIMIZER)
    end

    @testset "orderedindicestest" begin
        MOIT.orderedindicestest(OPTIMIZER)
    end

    @testset "copytest" begin
        MOIT.copytest(
            OPTIMIZER,
            MOI.Bridges.full_bridge_optimizer(GLPK.Optimizer(), Float64)
        )
    end

    @testset "scalar_function_constant_not_zero" begin
        MOIT.scalar_function_constant_not_zero(OPTIMIZER)
    end

    @testset "start_values_test" begin
        # We don't support ConstraintDualStart or ConstraintPrimalStart yet.
        # @test_broken MOIT.start_values_test(GLPK.Optimizer(), OPTIMIZER)
    end

    @testset "supports_constrainttest" begin
        # supports_constrainttest needs VectorOfVariables-in-Zeros,
        # MOIT.supports_constrainttest(GLPK.Optimizer(), Float64, Float32)
        # but supports_constrainttest is broken via bridges:
        MOI.empty!(OPTIMIZER)
        MOI.add_variable(OPTIMIZER)
        @test  MOI.supports_constraint(OPTIMIZER, MOI.SingleVariable, MOI.EqualTo{Float64})
        @test  MOI.supports_constraint(OPTIMIZER, MOI.ScalarAffineFunction{Float64}, MOI.EqualTo{Float64})
        # This test is broken for some reason:
        @test_broken !MOI.supports_constraint(OPTIMIZER, MOI.ScalarAffineFunction{Int}, MOI.EqualTo{Float64})
        @test !MOI.supports_constraint(OPTIMIZER, MOI.ScalarAffineFunction{Int}, MOI.EqualTo{Int})
        @test !MOI.supports_constraint(OPTIMIZER, MOI.SingleVariable, MOI.EqualTo{Int})
        @test  MOI.supports_constraint(OPTIMIZER, MOI.VectorOfVariables, MOI.Zeros)
        @test !MOI.supports_constraint(OPTIMIZER, MOI.VectorOfVariables, MOI.EqualTo{Float64})
        @test !MOI.supports_constraint(OPTIMIZER, MOI.SingleVariable, MOI.Zeros)
        @test !MOI.supports_constraint(OPTIMIZER, MOI.VectorOfVariables, MOIT.UnknownVectorSet)
    end

    @testset "set_lower_bound_twice" begin
        MOIT.set_lower_bound_twice(OPTIMIZER, Float64)
    end

    @testset "set_upper_bound_twice" begin
        MOIT.set_upper_bound_twice(OPTIMIZER, Float64)
    end
end

@testset "Parameter setting" begin
    solver = GLPK.Optimizer(tm_lim=1, ord_alg=2, alien=3)
    @test solver.simplex_param.tm_lim == 1
    @test solver.intopt_param.tm_lim == 1
    @test solver.interior_param.ord_alg == 2
    @test solver.intopt_param.alien == 3
end

@testset "Issue #79" begin
    @testset "An unbounded integer model" begin
        model = GLPK.Optimizer()
        MOI.Utilities.loadfromstring!(model, """
            variables: x, y
            minobjective: -5.0x + y
            c1: x in Integer()
            c2: x in LessThan(1.0)
        """)
        MOI.optimize!(model)
        @test MOI.get(model, MOI.TerminationStatus()) == MOI.DUAL_INFEASIBLE
    end

    @testset "An infeasible integer model" begin
        model = GLPK.Optimizer()
        MOI.Utilities.loadfromstring!(model, """
            variables: x
            minobjective: -5.0x
            c1: x in Integer()
            c2: x in LessThan(1.0)
            c3: 1.0x in GreaterThan(2.0)
        """)
        MOI.optimize!(model)
        @test MOI.get(model, MOI.TerminationStatus()) == MOI.INFEASIBLE
    end
end

@testset "Callbacks" begin
    @testset "Lazy cut" begin
        model = GLPK.Optimizer()
        MOI.Utilities.loadfromstring!(model, """
            variables: x, y
            maxobjective: y
            c1: x in Integer()
            c2: y in Integer()
            c3: x in Interval(0.0, 2.0)
            c4: y in Interval(0.0, 2.0)
        """)
        x = MOI.get(model, MOI.VariableIndex, "x")
        y = MOI.get(model, MOI.VariableIndex, "y")

        # We now define our callback function that takes the callback handle.
        # Note that we can access model, x, and y because this function is
        # defined inside the same scope.
        cb_calls = Int32[]
        function callback_function(cb_data::GLPK.CallbackData)
            reason = GLPK.ios_reason(cb_data.tree)
            push!(cb_calls, reason)
            if reason == GLPK.IROWGEN
                x_val = MOI.get(model, GLPK.CallbackVariablePrimal(cb_data), x)
                y_val = MOI.get(model, GLPK.CallbackVariablePrimal(cb_data), y)
                # We have two constraints, one cutting off the top
                # left corner and one cutting off the top right corner, e.g.
                # (0,2) +---+---+ (2,2)
                #       |xx/ \xx|
                #       |x/   \x|
                #       |/     \|
                # (0,1) +   +   + (2,1)
                #       |       |
                # (0,0) +---+---+ (2,0)
                TOL = 1e-6  # Allow for some impreciseness in the solution
                if y_val - x_val > 1 + TOL
                    GLPK.cblazy!(cb_data,
                        MOI.ScalarAffineFunction{Float64}(
                            MOI.ScalarAffineTerm.([-1.0, 1.0], [x, y]),
                            0.0
                        ),
                        MOI.LessThan{Float64}(1.0)
                    )
                elseif y_val + x_val > 3 + TOL
                    GLPK.cblazy!(cb_data,
                        MOI.ScalarAffineFunction{Float64}(
                            MOI.ScalarAffineTerm.([1.0, 1.0], [x, y]),
                            0.0
                        ),
                        MOI.LessThan{Float64}(3.0)
                    )
                end
            end
        end
        MOI.set(model, GLPK.CallbackFunction(), callback_function)
        MOI.optimize!(model)
        @test MOI.get(model, MOI.VariablePrimal(), x) == 1
        @test MOI.get(model, MOI.VariablePrimal(), y) == 2
        @test length(cb_calls) > 0
        @test GLPK.ISELECT in cb_calls
        @test GLPK.IPREPRO in cb_calls
        @test GLPK.IROWGEN in cb_calls
        @test GLPK.IBINGO in cb_calls
        @test !(GLPK.IHEUR in cb_calls)
    end
end

@testset "Issue #70" begin
    model = GLPK.Optimizer()
    x = MOI.add_variable(model)
    f =  MOI.ScalarAffineFunction(MOI.ScalarAffineTerm.([1.0], [x]), 0.0)
    s = MOI.LessThan(2.0)
    c = MOI.add_constraint(model, f, s)
    row = GLPK._info(model, c).row
    @test GLPK.get_row_type(model.inner, row) == GLPK.UP
    @test GLPK.get_row_lb(model.inner, row) == -GLPK.DBL_MAX
    @test GLPK.get_row_ub(model.inner, row) == 2.0
    # Modify the constraint set and verify that the internal constraint
    # has the correct bounds afterwards
    MOI.set(model, MOI.ConstraintSet(), c, MOI.LessThan(1.0))
    @test GLPK.get_row_type(model.inner, row) == GLPK.UP
    @test GLPK.get_row_lb(model.inner, row) == -GLPK.DBL_MAX
    @test GLPK.get_row_ub(model.inner, row) == 1.0
end

@testset "Infeasible bounds" begin
    model = GLPK.Optimizer()
    x = MOI.add_variable(model)
    MOI.add_constraint(model, MOI.SingleVariable(x), MOI.Interval(1.0, -1.0))
    MOI.optimize!(model)
    @test MOI.get(model, MOI.TerminationStatus()) == MOI.INVALID_MODEL
end

@testset "RawParameter" begin
    model = GLPK.Optimizer(method = GLPK.SIMPLEX)
    exception = ErrorException("Invalid option: cb_func. Use the MOI attribute `GLPK.CallbackFunction` instead.")
    @test_throws exception MOI.set(model, MOI.RawParameter("cb_func"), (cb) -> nothing)
    MOI.set(model, MOI.RawParameter("tm_lim"), 100)
    @test MOI.get(model, MOI.RawParameter("tm_lim")) == 100
    @test_throws ErrorException MOI.get(model, MOI.RawParameter(:tm_lim))
    @test_throws ErrorException MOI.set(model, MOI.RawParameter(:tm_lim), 120)
    @test_throws ErrorException MOI.set(model, MOI.RawParameter("bad"), 1)
    @test_throws ErrorException MOI.get(model, MOI.RawParameter("bad"))

    model = GLPK.Optimizer(method = GLPK.INTERIOR)
    exception = ErrorException("Invalid option: cb_func. Use the MOI attribute `GLPK.CallbackFunction` instead.")
    @test_throws exception MOI.set(model, MOI.RawParameter("cb_func"), (cb) -> nothing)
    MOI.set(model, MOI.RawParameter("tm_lim"), 100)
    @test MOI.get(model, MOI.RawParameter("tm_lim")) == 100
    @test_throws ErrorException MOI.set(model, MOI.RawParameter("bad"), 1)
    @test_throws ErrorException MOI.get(model, MOI.RawParameter("bad"))

    model = GLPK.Optimizer(method = GLPK.EXACT)
    exception = ErrorException("Invalid option: cb_func. Use the MOI attribute `GLPK.CallbackFunction` instead.")
    @test_throws exception MOI.set(model, MOI.RawParameter("cb_func"), (cb) -> nothing)
    MOI.set(model, MOI.RawParameter("tm_lim"), 100)
    @test MOI.get(model, MOI.RawParameter("tm_lim")) == 100
    @test_throws ErrorException MOI.set(model, MOI.RawParameter("bad"), 1)
    @test_throws ErrorException MOI.get(model, MOI.RawParameter("bad"))

    model = GLPK.Optimizer()
    MOI.set(model, MOI.RawParameter("mip_gap"), 0.001)
    @test MOI.get(model, MOI.RawParameter("mip_gap")) == 0.001
end

@testset "TimeLimitSec issue #110" begin
    model = GLPK.Optimizer(method = GLPK.SIMPLEX)
    MOI.set(model, MOI.TimeLimitSec(), nothing)
    @test MOI.get(model, MOI.RawParameter("tm_lim")) == typemax(Int32)
    MOI.set(model, MOI.TimeLimitSec(), 100)
    @test MOI.get(model, MOI.RawParameter("tm_lim")) == 100000
    @test MOI.get(model, MOI.TimeLimitSec()) == 100
    # conversion between ms and sec
    MOI.set(model, MOI.RawParameter("tm_lim"), 100)
    @test isapprox(MOI.get(model, MOI.TimeLimitSec()), 0.1)
end

@testset "RelativeGap" begin
    model = GLPK.Optimizer()
    MOI.Utilities.loadfromstring!(model, """
        variables: x
        minobjective: 1.0x
        c1: x in Integer()
        c2: x in GreaterThan(1.5)
    """)
    MOI.optimize!(model)
    @test MOI.get(model, MOI.RelativeGap()) == 0.0

    model = GLPK.Optimizer()
    MOI.Utilities.loadfromstring!(model, """
        variables: x
        minobjective: 1.0x
        c1: x in GreaterThan(1.5)
    """)
    MOI.optimize!(model)
    @test_throws ErrorException MOI.get(model, MOI.RelativeGap())
end

@testset "Extra name tests" begin
    model = GLPK.Optimizer()
    @testset "Variables" begin
        MOI.empty!(model)
        x = MOI.add_variables(model, 2)
        MOI.set(model, MOI.VariableName(), x[1], "x1")
        @test MOI.get(model, MOI.VariableIndex, "x1") == x[1]
        MOI.set(model, MOI.VariableName(), x[1], "x2")
        @test MOI.get(model, MOI.VariableIndex, "x1") === nothing
        @test MOI.get(model, MOI.VariableIndex, "x2") == x[1]
        MOI.set(model, MOI.VariableName(), x[2], "x1")
        @test MOI.get(model, MOI.VariableIndex, "x1") == x[2]
        MOI.set(model, MOI.VariableName(), x[1], "x1")
        @test_throws ErrorException MOI.get(model, MOI.VariableIndex, "x1")
    end

    @testset "Variable bounds" begin
        MOI.empty!(model)
        x = MOI.add_variable(model)
        c1 = MOI.add_constraint(model, MOI.SingleVariable(x), MOI.GreaterThan(0.0))
        c2 = MOI.add_constraint(model, MOI.SingleVariable(x), MOI.LessThan(1.0))
        MOI.set(model, MOI.ConstraintName(), c1, "c1")
        @test MOI.get(model, MOI.ConstraintIndex, "c1") == c1
        MOI.set(model, MOI.ConstraintName(), c1, "c2")
        @test MOI.get(model, MOI.ConstraintIndex, "c1") === nothing
        @test MOI.get(model, MOI.ConstraintIndex, "c2") == c1
        MOI.set(model, MOI.ConstraintName(), c2, "c1")
        @test MOI.get(model, MOI.ConstraintIndex, "c1") == c2
        MOI.set(model, MOI.ConstraintName(), c1, "c1")
        @test_throws ErrorException MOI.get(model, MOI.ConstraintIndex, "c1")
    end

    @testset "Affine constraints" begin
        MOI.empty!(model)
        x = MOI.add_variable(model)
        f = MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, x)], 0.0)
        c1 = MOI.add_constraint(model, f, MOI.GreaterThan(0.0))
        c2 = MOI.add_constraint(model, f, MOI.LessThan(1.0))
        MOI.set(model, MOI.ConstraintName(), c1, "c1")
        @test MOI.get(model, MOI.ConstraintIndex, "c1") == c1
        MOI.set(model, MOI.ConstraintName(), c1, "c2")
        @test MOI.get(model, MOI.ConstraintIndex, "c1") === nothing
        @test MOI.get(model, MOI.ConstraintIndex, "c2") == c1
        MOI.set(model, MOI.ConstraintName(), c2, "c1")
        @test MOI.get(model, MOI.ConstraintIndex, "c1") == c2
        MOI.set(model, MOI.ConstraintName(), c1, "c1")
        @test_throws ErrorException MOI.get(model, MOI.ConstraintIndex, "c1")
    end
end

@testset "Issue #102" begin
    model = GLPK.Optimizer()
    x = MOI.add_variable(model)
    MOI.add_constraint(model, MOI.SingleVariable(x), MOI.GreaterThan(0.0))
    MOI.add_constraint(model, MOI.SingleVariable(x), MOI.Integer())
    MOI.set(model, MOI.ObjectiveSense(), MOI.MIN_SENSE)
    MOI.set(
        model,
        MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}(),
        MOI.ScalarAffineFunction([MOI.ScalarAffineTerm(1.0, x)], 3.0)
    )
    MOI.optimize!(model)
    @test MOI.get(model, MOI.ObjectiveValue()) == 3.0
    @test MOI.get(model, MOI.ObjectiveBound()) == 3.0
end
