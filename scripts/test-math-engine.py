#!/usr/bin/env python3
"""Portable regression tests for the exact Python bootstrap shipped on iPhone.
Run with SymPy 1.14.0 / mpmath 1.3.0 installed. No model or network needed.
"""
import json
from pathlib import Path
import runpy
import unittest

ROOT = Path(__file__).resolve().parents[1]
ENGINE = runpy.run_path(str(ROOT / 'lilC/Infrastructure/math_bootstrap.py'), init_globals={'_math_packages': ''})


def calculate(operation, expression, **kwargs):
    return json.loads(ENGINE['_calculate_json'](json.dumps(dict(operation=operation, expression=expression, **kwargs))))


class MathEngineTests(unittest.TestCase):
    def test_exact_arithmetic_and_normalization(self):
        for source, expected in [('0.1+0.2', '3/10'), ('1/3+1/6', '1/2'), ('-3^2', '-9'),
                                 ('(-3)^2', '9'), ('2(3+4)', '14'), ('2×3−1', '5'),
                                 ('8-45/7', '11/7'), ('2³', '8'), ('1e3+1', '1001'),
                                 ('sin(pi/6)', '1/2'), ('cos(π)', '-1'), ('ln(e)', '1'),
                                 ('sqrt(2)^2', '2'), ('7^(2/3)', '7**(2/3)'), ('2^-3', '1/8')]:
            with self.subTest(source=source):
                result = calculate('evaluate', source)
                self.assertTrue(result['ok'], result)
                self.assertEqual(result['exact'], expected)

    def test_symbolic_operations(self):
        for op, source, expected in [('factor', 'x^2-4', '(x - 2)*(x + 2)'),
                                    ('expand', '(x+1)^2', 'x**2 + 2*x + 1'),
                                    ('simplify', 'sqrt(x^2)', 'Abs(x)'),
                                    ('differentiate', 'sin(x)', 'cos(x)'),
                                    ('differentiate', 'y^2', '0')]:
            with self.subTest(operation=op): self.assertEqual(calculate(op, source)['exact'], expected)
        self.assertEqual(calculate('differentiate', 'y^2', variable='y')['exact'], '2*y')

    def test_original_domain_is_not_cancelled_away(self):
        for source, expected in [('x/x', '1'), ('(x^2-1)/(x-1)', 'x + 1'), ('tan(x)-tan(x)', '0')]:
            result = calculate('simplify', source)
            self.assertEqual(result['exact'], expected)
            self.assertIn('neq', result['note'])
            self.assertIn('Original input conditions', result['note'])

    def test_equations_and_excluded_roots(self):
        for source, expected in [('2x+3=11', '{4}'), ('x^2=4', '{-2, 2}'),
                                 ('x^2+1=0', 'EmptySet'), ('1/x=2', '{1/2}'),
                                 ('(x^2-1)/(x-1)=2', 'EmptySet'), ('0*x=1', 'EmptySet'),
                                 ('0*x=0', 'Reals')]:
            with self.subTest(source=source): self.assertEqual(calculate('solve', source)['exact'], expected)
        self.assertIn('Union', calculate('solve', 'x/x=1')['exact'])
        self.assertEqual(calculate('solve', 'y^2=4', variable='y')['exact'], '{-2, 2}')

    def test_integrals(self):
        result = calculate('integrate', 'x^2')
        self.assertEqual(result['exact'], 'x**3/3')
        self.assertTrue(result['latex'].endswith(' + C'))
        self.assertEqual(calculate('integrate', '1/x')['exact'], 'log(Abs(x))')
        self.assertEqual(calculate('integrate', 'x^2', lower='0', upper='1')['exact'], '1/3')
        self.assertEqual(calculate('integrate', 'x', lower='1', upper='0')['exact'], '-1/2')
        self.assertFalse(calculate('integrate', '1/x', lower='-1', upper='1')['ok'])
        self.assertFalse(calculate('integrate', 'x', lower='0')['ok'])
        self.assertFalse(calculate('integrate', 'x', lower='x', upper='1')['ok'])

    def test_matrices(self):
        self.assertEqual(calculate('determinant', '[[1,2],[3,4]]')['exact'], '-2')
        self.assertEqual(calculate('inverse', '[[1,2],[3,4]]')['exact'], 'Matrix([[-2, 1], [3/2, -1/2]])')
        self.assertEqual(calculate('rank', '[[1,2],[2,4]]')['exact'], '1')
        result = calculate('rref', '[[1,1,2],[2,3,5]]')
        self.assertEqual(result['exact'], 'Matrix([[1, 0, 1], [0, 1, 1]])')
        self.assertIn('1, 2', result['note'])
        self.assertEqual(calculate('inverse', '[["1/2",0],[0,1]]')['exact'], 'Matrix([[2, 0], [0, 1]])')
        for op, source in [('inverse', '[[1,2],[2,4]]'), ('inverse', '[[1,2]]'),
                           ('rref', '[[1],[1,2]]'), ('rank', '[[]]'), ('rank', '[]'),
                           ('rank', '[["x"]]'), ('rank', '[[true]]'), ('rank', '[[NaN]]')]:
            with self.subTest(op=op, source=source): self.assertFalse(calculate(op, source)['ok'])

    def test_statistics(self):
        for op, expected in [('mean', '2'), ('median', '2'), ('variance', '2/3'),
                             ('sample_variance', '1'), ('stddev', 'sqrt(6)/3'), ('sample_stddev', '1')]:
            with self.subTest(op=op): self.assertEqual(calculate(op, '[1,2,3]')['exact'], expected)
        self.assertEqual(calculate('median', '[4,1,3,2]')['exact'], '5/2')
        self.assertEqual(calculate('mean', '["1/2","3/4"]')['exact'], '5/8')
        self.assertFalse(calculate('sample_variance', '[1]')['ok'])
        self.assertFalse(calculate('mean', '[]')['ok'])
        self.assertFalse(calculate('mean', json.dumps(list(range(41))))['ok'])

    def test_invalid_and_unbounded_inputs(self):
        for source in ['1/0', '0/0', '0*(1/0)', 'sqrt(-1)', 'log(0)', '0^0', '0^-1',
                       '10^100', '2^x', '1e999', '9'*25, '(10^20)^20^20',
                       '((((10^20)^20)^20)^20)', 'x' * 401, '(' * 30 + '1' + ')' * 30,
                       'sin(1,2)', 'foo(2)', '1 2', '1//2', '5%2', '0xFF']:
            with self.subTest(source=source): self.assertFalse(calculate('evaluate', source)['ok'])
        self.assertFalse(calculate('expand', '(x+y+z+a+b+c)^20')['ok'])
        self.assertFalse(calculate('solve', 'x^5=1')['ok'])
        self.assertFalse(calculate('solve', 'x+y=1')['ok'])
        self.assertFalse(calculate('solve', 'sin(x)=0')['ok'])
        self.assertFalse(calculate('evaluate', '1', lower='0', upper='1')['ok'])
        self.assertFalse(calculate('unknown', '1')['ok'])

    def test_no_code_execution(self):
        for source in ["__import__('os').system('echo unsafe')", '(1).__class__', '[x for x in [1]]',
                       'open("/tmp/unsafe","w")', 'lambda: 1', 'x[0]', 'x:=1',
                       'sin(x, evaluate=True)', '1;2', '1 # comment', 'getattr(x,"a")']:
            with self.subTest(source=source): self.assertFalse(calculate('evaluate', source)['ok'])
        for request in ['null', '[]', '{}', '{"operation":[],"expression":"1"}', '{"operation":"evaluate","expression":"1","variable":[]}']:
            self.assertFalse(json.loads(ENGINE['_calculate_json'](request))['ok'])

    def test_timeout_is_not_swallowed(self):
        function = ENGINE['_calculate_json']
        original = function.__globals__['calculate']
        def timeout(_): raise TimeoutError('deadline')
        try:
            function.__globals__['calculate'] = timeout
            with self.assertRaises(TimeoutError): function('{}')
        finally: function.__globals__['calculate'] = original


if __name__ == '__main__': unittest.main()
