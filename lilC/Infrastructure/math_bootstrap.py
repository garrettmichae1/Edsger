"""Bounded, real-domain calculator. Mathematical input is data, never Python code.

Only the AST allowlist below constructs SymPy objects. Do not replace it with
sympify/parse_expr/eval on request strings. The host enforces a traced deadline.
"""
import ast
import io
import json
import math
import re
import sys
import tokenize
sys.path.insert(0, _math_packages)
import sympy as s
from sympy.calculus.util import continuous_domain

_FUNCTIONS = {'sin': s.sin, 'cos': s.cos, 'tan': s.tan, 'asin': s.asin,
              'acos': s.acos, 'atan': s.atan, 'exp': s.exp, 'log': s.log,
              'ln': s.log, 'sqrt': s.sqrt, 'abs': s.Abs}
_SYMBOLS = {name: s.Symbol(name, real=True) for name in ('x', 'y', 'z', 't', 'a', 'b', 'c', 'n')}
_CONSTANTS = {'pi': s.pi, 'e': s.E, 'E': s.E}
_MATRIX_OPS = {'determinant', 'inverse', 'rref', 'rank'}
_STATS_OPS = {'mean', 'median', 'variance', 'sample_variance', 'stddev', 'sample_stddev'}
_OPERATIONS = _MATRIX_OPS | _STATS_OPS | {'evaluate', 'simplify', 'expand', 'factor', 'differentiate', 'integrate', 'solve'}


def normalize(source):
    if not isinstance(source, str) or not 0 < len(source.encode('utf-8')) <= 400:
        raise ValueError('Use a shorter expression (up to 400 UTF-8 bytes).')
    source = source.strip().translate(str.maketrans({'−': '-', '×': '*', '÷': '/', 'π': 'pi'}))
    source = re.sub(r'([⁰¹²³⁴⁵⁶⁷⁸⁹]+)', lambda m: '^(' + m[0].translate(str.maketrans('⁰¹²³⁴⁵⁶⁷⁸⁹', '0123456789')) + ')', source)
    source = source.replace('^', '**')
    tokens = [t for t in tokenize.generate_tokens(io.StringIO(source).readline)
              if t.type not in (tokenize.NEWLINE, tokenize.ENDMARKER)]
    result = []
    nesting = 0
    previous = None
    for token in tokens:
        kind, text = token.type, token.string
        if text == "(": nesting += 1
        if text == ")": nesting -= 1
        if nesting > 16: raise ValueError("This expression is nested too deeply.")
        if kind == tokenize.NAME and text not in _SYMBOLS and text not in _CONSTANTS and text not in _FUNCTIONS:
            raise ValueError('Use x, y, z, t, a, b, c, n, pi, e, or a supported math function.')
        if kind not in (tokenize.NUMBER, tokenize.NAME, tokenize.OP) or (kind == tokenize.OP and text not in ('+', '-', '*', '/', '**', '(', ')')):
            raise ValueError('Use only numbers, supported symbols/functions, parentheses, and + - * / ^.')
        if previous:
            pk, pt = previous.type, previous.string
            if pk == tokenize.NUMBER and kind == tokenize.NUMBER:
                raise ValueError('Put an operator between numbers.')
            ends = pk in (tokenize.NUMBER, tokenize.NAME) or pt == ')'
            starts = kind in (tokenize.NUMBER, tokenize.NAME) or text == '('
            function_call = pk == tokenize.NAME and pt in _FUNCTIONS and text == '('
            if ends and starts and not function_call:
                result.append('*')
        result.append(text)
        previous = token
    return ''.join(result)


def bounded(value):
    # Check at each construction, before a later power can amplify an intermediate.
    if value.has(s.zoo, s.nan) or (not isinstance(value, s.Set) and value.has(s.oo, -s.oo)):
        raise ValueError('The expression is undefined or unbounded.')
    if s.count_ops(value) > 160:
        raise ValueError('This expression is too complex. Try a smaller calculation.')
    for number in value.atoms(s.Rational):
        if int(number.p).bit_length() > 4096 or int(number.q).bit_length() > 4096:
            raise ValueError('The numbers in this calculation are too large.')
    return value


class Expression:
    def __init__(self, source):
        self.denominators = []
        self.conditions = []
        source = normalize(source)
        tree = ast.parse(source, mode='eval')
        if sum(1 for _ in ast.walk(tree)) > 120:
            raise ValueError('This expression is too complex.')

        def visit(node, depth=0):
            if depth > 16: raise ValueError('This expression is nested too deeply.')
            if isinstance(node, ast.Constant) and type(node.value) in (int, float):
                raw = ast.get_source_segment(source, node)
                if not raw or len(raw) > 24 or not math.isfinite(node.value) or abs(node.value) > 1e12:
                    raise ValueError('Number is outside the supported range.')
                value = s.Rational(raw)
            elif isinstance(node, ast.Name):
                if node.id in _SYMBOLS: return _SYMBOLS[node.id]
                if node.id in _CONSTANTS: return _CONSTANTS[node.id]
                raise ValueError('A function must have one parenthesized argument.')
            elif isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
                item = visit(node.operand, depth + 1)
                value = s.Mul(-1, item, evaluate=False) if isinstance(node.op, ast.USub) else item
            elif isinstance(node, ast.BinOp):
                left, right = visit(node.left, depth + 1), visit(node.right, depth + 1)
                if isinstance(node.op, ast.Add): value = s.Add(left, right, evaluate=False)
                elif isinstance(node.op, ast.Sub): value = s.Add(left, s.Mul(-1, right, evaluate=False), evaluate=False)
                elif isinstance(node.op, ast.Mult): value = s.Mul(left, right, evaluate=False)
                elif isinstance(node.op, ast.Div):
                    if right.doit().is_zero is True: raise ValueError('Division by zero is undefined.')
                    self.denominators.append(right)
                    self.conditions.append(s.Ne(right, 0, evaluate=False))
                    value = s.Mul(left, s.Pow(right, -1, evaluate=False), evaluate=False)
                elif isinstance(node.op, ast.Pow):
                    exponent = bounded(right.doit())
                    if not exponent.is_number or exponent.is_real is not True or abs(exponent) > 20:
                        raise ValueError('Use numeric powers between -20 and 20; symbolic exponents are not supported.')
                    base = bounded(left.doit())
                    if base.is_zero is True and exponent.is_zero is True:
                        raise ValueError('0^0 is indeterminate. Please clarify the intended calculation.')
                    if exponent.is_negative:
                        if base.is_zero is True: raise ValueError('Division by zero is undefined.')
                        self.denominators.append(left)
                        self.conditions.append(s.Ne(left, 0, evaluate=False))
                    if not exponent.is_integer:
                        self.conditions.append(s.Ge(left, 0, evaluate=False))
                    if base.is_Rational and exponent.is_Integer:
                        bits = max(int(base.p).bit_length(), int(base.q).bit_length()) * abs(int(exponent))
                        if bits > 4096: raise ValueError('That power would produce a number that is too large.')
                    if s.count_ops(base) > 24: raise ValueError('The power base is too complex.')
                    value = s.Pow(left, exponent, evaluate=False)
                else: raise ValueError('Unsupported operator.')
            elif isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in _FUNCTIONS and len(node.args) == 1 and not node.keywords:
                argument = visit(node.args[0], depth + 1)
                name = node.func.id
                if name in ('sqrt',): self.conditions.append(s.Ge(argument, 0, evaluate=False))
                if name in ('log', 'ln'): self.conditions.append(s.Gt(argument, 0, evaluate=False))
                if name == 'tan': self.conditions.append(s.Ne(s.cos(argument), 0, evaluate=False))
                if name in ('asin', 'acos'):
                    self.conditions.extend([s.Ge(argument, -1, evaluate=False), s.Le(argument, 1, evaluate=False)])
                value = _FUNCTIONS[name](argument, evaluate=False)
            else:
                raise ValueError('Use mathematical expressions only; arbitrary code is not accepted.')
            # Evaluation is only of objects built by this allowlist, never a source string.
            checked = bounded(value.doit())
            if not checked.free_symbols and checked.is_real is False:
                raise ValueError('This calculation is outside the real-number domain.')
            return value

        self.value = visit(tree.body)


def expansion_cost(value):
    if value.is_Add: return min(2001, sum(expansion_cost(v) for v in value.args))
    if value.is_Mul:
        count = 1
        for v in value.args:
            count *= expansion_cost(v)
            if count > 2000: return 2001
        return count
    if value.is_Pow and value.exp.is_Integer and value.exp > 0:
        terms = expansion_cost(value.base)
        return min(2001, math.comb(terms + int(value.exp) - 1, int(value.exp)))
    return 1


def array_number(value):
    if type(value) in (int, float):
        if not math.isfinite(value) or abs(value) > 1e6: raise ValueError('Use finite numeric array entries up to 1,000,000.')
        text = str(value)
    elif isinstance(value, str) and len(value) <= 40:
        text = value
    else: raise ValueError('Use numeric array entries or fractions such as "1/3".')
    item = Expression(text).value.doit()
    if item.free_symbols or item.is_real is not True or item.is_finite is not True or abs(item) > 1e6:
        raise ValueError('Array entries must be finite real numbers up to 1,000,000.')
    return item


def integral_work(original, variable, result, bounds):
    """Small allowlist of student-style rules. Failure leaves the existing answer intact.

    Only trusted SymPy objects enter here; no model text, LaTeX, or source eval.
    Captions/equations are rendered by the app without an explanatory model pass.
    """
    from sympy.integrals import manualintegrate as m
    if bounds:
        domain = s.Interval(min(bounds), max(bounds))
    else:
        domain = continuous_domain(original, variable, s.S.Reals)
    canonical = bounded(original.doit())
    rule = m.integral_steps(canonical, variable)
    allowed = {m.ConstantRule, m.PowerRule, m.ReciprocalRule, m.ExpRule,
               m.SinRule, m.CosRule, m.ArctanRule, m.AddRule, m.ConstantTimesRule,
               m.PartsRule, m.RewriteRule, m.AlternativeRule, m.URule}
    nodes, pending = [], [(rule, 0, {})]
    while pending:
        node, depth, substitutions = pending.pop()
        if type(node) not in allowed or depth > 8 or len(nodes) >= 32:
            return None
        if isinstance(node, m.AlternativeRule):
            if not node.alternatives: return None
            pending.append((node.alternatives[0], depth + 1, substitutions))
            continue
        nodes.append((node, substitutions))
        if isinstance(node, m.PartsRule):
            if node.second_step is None: return None
            children = [node.v_step, node.second_step]
        elif isinstance(node, m.AddRule): children = node.substeps
        elif isinstance(node, (m.ConstantTimesRule, m.RewriteRule)): children = [node.substep]
        elif isinstance(node, m.URule):
            substitutions = dict(substitutions)
            substitutions[node.u_var] = node.u_func.xreplace(substitutions)
            children = [node.substep]
        else: children = []
        pending.extend((child, depth + 1, substitutions) for child in reversed(children))
    if not nodes: return None
    # Reject narrowing domains (e.g. log(x) on a negative real interval), unresolved
    # derivatives and rewrites. Symbolic equality alone is not a domain check.
    for node, substitutions in nodes:
        integrated = bounded(node.eval())
        if integrated.has(s.Integral) or s.simplify(s.diff(integrated, node.variable) - node.integrand) != 0:
            return None
        expressions = [node.integrand, integrated]
        if isinstance(node, m.PartsRule):
            v = node.v_step.eval()
            if (s.simplify(node.u*node.dv - node.integrand) != 0 or
                s.simplify(s.diff(v, node.variable) - node.dv) != 0 or
                s.simplify(s.diff(node.u, node.variable)*v - node.second_step.integrand) != 0): return None
            expressions.extend([node.u, node.dv, v])
        if isinstance(node, m.RewriteRule):
            if s.simplify(node.integrand - node.rewritten) != 0: return None
            expressions.append(node.rewritten)
        for expression in expressions:
            expression = expression.xreplace(substitutions)
            if domain.is_subset(continuous_domain(expression, variable, s.S.Reals)) is not True:
                return None
    antiderivative = bounded(rule.eval())
    if s.simplify(s.diff(antiderivative, variable) - canonical) != 0: return None
    if bounds:
        values = [bounded(s.simplify(antiderivative.subs(variable, bound))) for bound in bounds]
        if any(v.is_real is not True or v.is_finite is not True for v in values): return None
        if s.simplify(values[1] - values[0] - result) != 0: return None
    elif s.simplify(antiderivative - result) != 0:
        return None
    steps = []
    def add(title, latex):
        if len(latex.encode('utf-8')) > 1400: raise ValueError('Work display limit.')
        steps.append({'title': title, 'latex': latex})
    parts = next((node for node, substitutions in nodes if isinstance(node, m.PartsRule) and not substitutions), None)
    if parts is not None:
        u, dv, v = parts.u, parts.dv, parts.v_step.eval()
        du = s.diff(u, variable)
        add('Use integration by parts', r'\begin{aligned}u &= ' + s.latex(u) +
            r'\\ dv &= ' + s.latex(dv) + r'\,d' + s.latex(variable) +
            r'\\ du &= ' + s.latex(du) + r'\,d' + s.latex(variable) + r'\\ v &= ' + s.latex(v) + r'\end{aligned}')
        add('Apply the integration-by-parts formula', s.latex(s.Integral(parts.integrand, variable)) +
            ' = ' + s.latex(u*v) + ' - ' + s.latex(s.Integral(du*v, variable)))
    rewrite = next((node for node, substitutions in nodes if isinstance(node, m.RewriteRule) and not substitutions), None)
    if rewrite is not None:
        add('Rewrite the integrand', s.latex(rewrite.integrand) + ' = ' + s.latex(rewrite.rewritten))
    add('Find an antiderivative', 'F(' + s.latex(variable) + ') = ' + s.latex(antiderivative))
    if bounds:
        add('Evaluate the upper and lower bounds',
            'F(' + s.latex(bounds[1]) + ') - F(' + s.latex(bounds[0]) + ') = ' +
            r'\left(' + s.latex(values[1]) + r'\right) - \left(' + s.latex(values[0]) + r'\right) = ' + s.latex(result))
    else:
        add('Include the integration constant', s.latex(s.Integral(original, variable)) + ' = ' + s.latex(result) + ' + C')
    if len(steps) > 6 or sum(len(v.encode('utf-8')) for step in steps for v in step.values()) > 5000:
        return None
    return steps


def calculate(request):
    if not isinstance(request, dict) or set(request) - {'operation', 'expression', 'variable', 'lower', 'upper', 'include_work'}:
        raise ValueError('Invalid calculation request.')
    operation = request.get('operation')
    if not isinstance(operation, str) or operation not in _OPERATIONS: raise ValueError('Unsupported calculation.')
    include_work = request.get('include_work', False)
    if type(include_work) is not bool or (include_work and operation != 'integrate'):
        raise ValueError('Work is only supported for integration requests.')
    variable = request.get('variable', 'x')
    if not isinstance(variable, str) or variable not in _SYMBOLS: raise ValueError('Unsupported variable.')
    x = _SYMBOLS[variable]
    source = request.get('expression', '')
    lower, upper = request.get('lower', ''), request.get('upper', '')
    if not isinstance(source, str) or not 0 < len(source.encode('utf-8')) <= 400: raise ValueError('Expression limit is 400 UTF-8 bytes.')
    if any(not isinstance(v, str) or len(v.encode('utf-8')) > 80 for v in (lower, upper)):
        raise ValueError('Bounds must be expressions of at most 80 UTF-8 bytes.')
    if (lower or upper) and operation != 'integrate': raise ValueError('Bounds are only supported for integration.')
    if bool(lower) != bool(upper): raise ValueError('Supply both integration bounds or neither.')
    note = 'Symbols are real. Trigonometric arguments use radians.'
    conditions = []
    if operation in _MATRIX_OPS | _STATS_OPS:
        values = json.loads(source)
        if operation in _MATRIX_OPS:
            if not isinstance(values, list) or not 1 <= len(values) <= 4 or not isinstance(values[0], list) or not 1 <= len(values[0]) <= 5:
                raise ValueError('Use a numeric matrix up to 4 rows and 5 columns.')
            columns = len(values[0])
            if any(not isinstance(row, list) or len(row) != columns for row in values):
                raise ValueError('Every matrix row must have the same number of entries.')
            if operation in ('determinant', 'inverse') and columns != len(values):
                raise ValueError('Determinants and inverses require a square matrix up to 4 by 4.')
            original = s.Matrix([[array_number(v) for v in row] for row in values])
            if operation == 'determinant': result = original.det()
            elif operation == 'inverse':
                if original.det() == 0: raise ValueError('This matrix is singular, so it has no inverse.')
                result = original.inv()
            elif operation == 'rank': result = s.Integer(original.rank())
            else:
                result, pivots = original.rref()
                note = 'Pivot columns (numbered from 1): ' + (', '.join(str(p + 1) for p in pivots) or 'none') + '.'
        else:
            if not isinstance(values, list) or not 1 <= len(values) <= 40: raise ValueError('Use 1 to 40 numbers.')
            numbers = [array_number(v) for v in values]
            original = s.Tuple(*numbers)
            mean = sum(numbers) / len(numbers)
            if operation == 'mean': result, note = mean, 'Arithmetic mean.'
            elif operation == 'median':
                ordered = sorted(numbers)
                mid = len(numbers) // 2
                result = ordered[mid] if len(numbers) % 2 else (ordered[mid - 1] + ordered[mid]) / 2
                note = 'Median of the sorted data.'
            else:
                sample = operation.startswith('sample_')
                if sample and len(numbers) < 2: raise ValueError('Sample variance and deviation require at least two numbers.')
                divisor = len(numbers) - (1 if sample else 0)
                result = sum((v - mean)**2 for v in numbers) / divisor
                if operation.endswith('stddev'): result = s.sqrt(result)
                note = 'Sample definition (divide by N − 1).' if sample else 'Population definition (divide by N).'
    elif operation == 'solve':
        parts = source.split('=')
        if len(parts) != 2: raise ValueError('Give one equation with an equals sign.')
        left, right = [Expression(part) for part in parts]
        original = s.Eq(left.value, right.value, evaluate=False)
        conditions = left.conditions + right.conditions
        if (left.value.free_symbols | right.value.free_symbols) - {x}:
            raise ValueError('Solving supports one variable with numeric coefficients.')
        if not left.value.is_rational_function(x) or not right.value.is_rational_function(x):
            raise ValueError('Solving currently supports polynomial and rational equations only.')
        expression = left.value - right.value
        numerator, denominator = s.fraction(s.together(expression))
        for part in (numerator, denominator):
            if s.Poly(part, x).degree() > 4: raise ValueError('Solving supports polynomials through degree 4.')
        result = s.solveset(numerator, x, domain=s.S.Reals)
        for excluded in left.denominators + right.denominators + [denominator]:
            if s.Poly(s.fraction(s.together(excluded))[0], x).degree() > 4:
                raise ValueError('A denominator exceeds the supported solving degree.')
            result = result - s.solveset(excluded, x, domain=s.S.Reals)
        if result.has(s.ConditionSet): raise ValueError('The solver could not determine a complete solution set.')
        note = 'Solutions over the real numbers; original denominator exclusions are preserved.'
        if result == s.S.EmptySet: note += ' No real solutions.'
    else:
        parsed = Expression(source)
        original = parsed.value
        conditions = parsed.conditions
        if operation == 'evaluate':
            if original.free_symbols: raise ValueError('Provide values for the variables before a numeric calculation.')
            result = s.simplify(original)
        elif operation == 'simplify': result = s.simplify(original)
        elif operation == 'expand':
            if expansion_cost(original) > 2000: raise ValueError('That expansion is too large. Use fewer terms or a smaller power.')
            result = s.expand(original)
        elif operation == 'factor': result = s.factor(original)
        elif operation == 'differentiate':
            result = s.diff(original, x)
            note = 'First derivative with respect to ' + variable + '. Valid where the original function is differentiable; endpoint and discontinuity values may be excluded.'
        elif operation == 'integrate':
            if lower:
                lo, hi = Expression(lower).value.doit(), Expression(upper).value.doit()
                if any(v.free_symbols or v.is_real is not True or v.is_finite is not True for v in (lo, hi)):
                    raise ValueError('Use finite real numeric integration bounds.')
                interval = s.Interval(min(lo, hi), max(lo, hi))
                if continuous_domain(original, x, interval) != interval:
                    raise ValueError('The interval crosses an undefined point. Improper integrals are not supported.')
                result = s.integrate(original, (x, lo, hi))
                note = 'Definite integral with bounds ' + str(lo) + ' to ' + str(hi) + '.'
            else:
                result = s.integrate(original, x)
                # For real rational functions, log|u| gives the real antiderivative on each domain interval.
                if original.is_rational_function(x):
                    result = result.replace(lambda v: v.func == s.log and v.args[0].is_real is True,
                                            lambda v: s.log(s.Abs(v.args[0])))
                note = 'Indefinite integral: C is arbitrary; valid on intervals in the original real domain.'
            if result.has(s.Integral): raise ValueError('An exact integral was not found. Try a simpler integrand.')
    result = bounded(result)
    if not result.free_symbols and getattr(result, 'is_real', None) is False:
        raise ValueError('This result is outside the real-number domain.')
    visible_conditions = []
    for condition in conditions:
        simplified = s.simplify(condition)
        if simplified == s.false: raise ValueError('The input is outside the real-number domain.')
        if simplified != s.true:
            latex_condition = s.latex(simplified)
            if latex_condition not in visible_conditions: visible_conditions.append(latex_condition)
    if visible_conditions:
        note += '\n\nOriginal input conditions: \\(' + r',\quad '.join(visible_conditions) + '\\).'
    if conditions: note += ' Simplification does not remove original input restrictions.'
    latex, exact, input_latex = s.latex(result), str(result), s.latex(original)
    if operation == 'integrate' and not lower: latex += ' + C'
    if any(len(v) > 2500 for v in (latex, exact, input_latex)) or len(note) > 2500:
        raise ValueError('The result is too large to display safely.')
    answer = {'ok': True, 'input': input_latex, 'latex': latex, 'exact': exact, 'note': note}
    if include_work:
        try:
            steps = integral_work(original, x, result, (lo, hi) if lower else None)
            if steps: answer['steps'] = steps
        except (TimeoutError, KeyboardInterrupt):
            raise  # Host cancellation/deadline semantics must remain unchanged.
        except Exception:
            pass  # A failed optional derivation must not replace a successful calculation.
    return answer


def _calculate_json(raw):
    try:
        if not isinstance(raw, str) or len(raw.encode('utf-8')) > 4096: raise ValueError('Calculation request is too large.')
        answer = calculate(json.loads(raw))
        encoded = json.dumps(answer, ensure_ascii=True, allow_nan=False)
        if 'steps' in answer and len(encoded.encode('utf-8')) > 16384:
            del answer['steps']
            encoded = json.dumps(answer, ensure_ascii=True, allow_nan=False)
        return encoded
    except (TimeoutError, KeyboardInterrupt):
        # The host must observe interruption; never turn a deadline into a successful transport response.
        raise
    except (ValueError, SyntaxError, tokenize.TokenError, s.PolynomialError) as error:
        return json.dumps({'ok': False, 'error': str(error)[:240]})
    except Exception:
        return json.dumps({'ok': False, 'error': 'This calculation could not be completed within the supported methods. Try a simpler expression.'})
