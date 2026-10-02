"""Trusted, bounded calculator. Request strings are parsed as data, never evaluated."""
import ast
import json
import sys
import time
sys.path.insert(0, _math_packages)
import sympy as s

_FUNCTIONS = {'sin': s.sin, 'cos': s.cos, 'tan': s.tan, 'asin': s.asin,
              'acos': s.acos, 'atan': s.atan, 'exp': s.exp, 'log': s.log,
              'sqrt': s.sqrt, 'abs': s.Abs}
_SYMBOLS = {name: s.Symbol(name, real=True) for name in ('x', 'y', 'z', 't', 'a', 'b', 'c', 'n')}
_CONSTANTS = {'pi': s.pi, 'e': s.E, 'E': s.E}


def expression(source):
    if not isinstance(source, str) or not 0 < len(source) <= 400:
        raise ValueError('Use a shorter expression (up to 400 characters).')
    tree = ast.parse(source.replace('^', '**'), mode='eval')
    if sum(1 for _ in ast.walk(tree)) > 120:
        raise ValueError('This expression is too complex.')

    def visit(node, depth=0):
        if depth > 16:
            raise ValueError('This expression is nested too deeply.')
        if isinstance(node, ast.Constant) and type(node.value) in (int, float):
            raw = ast.get_source_segment(source.replace('^', '**'), node)
            if not raw or len(raw) > 24 or abs(node.value) > 1e12:
                raise ValueError('Number is outside the supported range.')
            return s.Rational(raw)
        if isinstance(node, ast.Name):
            if node.id in _SYMBOLS: return _SYMBOLS[node.id]
            if node.id in _CONSTANTS: return _CONSTANTS[node.id]
            raise ValueError('Use x, y, z, t, a, b, c, n, pi, or e.')
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
            item = visit(node.operand, depth + 1)
            return -item if isinstance(node.op, ast.USub) else item
        if isinstance(node, ast.BinOp):
            left, right = visit(node.left, depth + 1), visit(node.right, depth + 1)
            if isinstance(node.op, ast.Add): return left + right
            if isinstance(node.op, ast.Sub): return left - right
            if isinstance(node.op, ast.Mult): return left * right
            if isinstance(node.op, ast.Div):
                if right == 0: raise ValueError('Division by zero is undefined.')
                return left / right
            if isinstance(node.op, ast.Pow):
                if right.is_number and (not right.is_real or abs(right) > 20):
                    raise ValueError('Use numeric powers between -20 and 20.')
                if s.count_ops(left) > 20: raise ValueError('Power base is too complex.')
                return left ** right
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in _FUNCTIONS and len(node.args) == 1 and not node.keywords:
            return _FUNCTIONS[node.func.id](visit(node.args[0], depth + 1))
        raise ValueError('Use mathematical expressions only; code, attributes, and indexing are not accepted.')
    result = visit(tree.body)
    if result.has(s.zoo, s.nan, s.oo, -s.oo): raise ValueError('The expression is undefined or unbounded.')
    return result


def calculate(request):
    if not isinstance(request, dict): raise ValueError('Invalid calculation request.')
    operation = request.get('operation')
    variable = request.get('variable', 'x')
    if variable not in _SYMBOLS: raise ValueError('Unsupported variable.')
    x = _SYMBOLS[variable]
    source = request.get('expression', '')
    lower, upper = request.get('lower', ''), request.get('upper', '')
    note = 'Symbols are treated as real numbers. Domain restrictions still apply.'
    if operation in ('determinant', 'inverse', 'mean', 'variance'):
        # JSON numeric arrays only; strings and symbolic constructors are not accepted here.
        if not isinstance(source, str) or len(source) > 400: raise ValueError('Array is too large.')
        values = json.loads(source)
        def number(v):
            if type(v) not in (int, float) or abs(v) > 1e6: raise ValueError('Use finite numeric array entries.')
            return expression(str(v))
        if operation in ('determinant', 'inverse'):
            if not isinstance(values, list) or not 1 <= len(values) <= 4 or any(not isinstance(row, list) or len(row) != len(values) for row in values):
                raise ValueError('Use a square numeric matrix up to 4 by 4.')
            original = s.Matrix([[number(v) for v in row] for row in values])
            result = original.det() if operation == 'determinant' else original.inv()
        else:
            if not isinstance(values, list) or not 1 <= len(values) <= 40: raise ValueError('Use 1 to 40 numbers.')
            numbers = [number(v) for v in values]
            original = s.Tuple(*numbers)
            mean = sum(numbers) / len(numbers)
            result = mean if operation == 'mean' else sum((v - mean)**2 for v in numbers) / len(numbers)
            note = 'Variance uses the population definition (divide by N).' if operation == 'variance' else 'Arithmetic mean.'
    else:
        if operation == 'solve':
            parts = source.split('=')
            if len(parts) != 2: raise ValueError('Give one equation with an equals sign.')
            left, right = map(expression, parts)
            original = s.Eq(left, right, evaluate=False)
            polynomial = s.Poly(left - right, x)
            if polynomial.total_degree() > 4 or (left - right).free_symbols - {x}:
                raise ValueError('Solving supports one-variable numeric polynomials through degree 4.')
            result = s.solveset(left - right, x, domain=s.S.Reals)
            note = 'Solutions over the real numbers.'
        else:
            original = expression(source)
            if operation == 'evaluate':
                if original.free_symbols: raise ValueError('A numeric calculation cannot contain unknown variables.')
                result = original
            elif operation == 'simplify': result = s.simplify(original)
            elif operation == 'expand': result = s.expand(original)
            elif operation == 'factor': result = s.factor(original)
            elif operation == 'differentiate': result = s.diff(original, x)
            elif operation == 'integrate':
                if bool(lower) != bool(upper): raise ValueError('Supply both bounds or neither.')
                if lower:
                    lo, hi = expression(lower), expression(upper)
                    if lo.free_symbols or hi.free_symbols or lo.is_real is not True or hi.is_real is not True:
                        raise ValueError('Use finite real numeric integration bounds.')
                    result = s.integrate(original, (x, lo, hi))
                    note = 'Definite integral with bounds ' + str(lo) + ' to ' + str(hi) + '.'
                else:
                    result = s.integrate(original, x)
                    note = 'Indefinite integral: add an arbitrary constant C.'
                if result.has(s.Integral): raise ValueError('An exact integral was not found within the supported method.')
            else: raise ValueError('Unsupported calculation.')
    if result.has(s.zoo, s.nan, s.oo, -s.oo): raise ValueError('The result is undefined or unbounded.')
    latex = s.latex(result)
    if operation == 'integrate' and not lower: latex += ' + C'
    if len(latex) > 2500: raise ValueError('The result is too large to display safely.')
    return {'ok': True, 'input': s.latex(original), 'latex': latex, 'exact': str(result), 'note': note}


def _calculate_json(raw):
    try:
        return json.dumps(calculate(json.loads(raw)), ensure_ascii=True)
    except Exception as error:
        return json.dumps({'ok': False, 'error': str(error)[:240]})
