// Parse source before adding cooperative Stop checkpoints; never rewrite strings/comments.
(function () {
    const parse = acorn.parse;
    const compile = __lilc_compile;
    delete globalThis.__lilc_compile;
    const cache = Object.create(null);
    function prepare(source) {
        const ast = parse(source, {ecmaVersion: 2025, sourceType: 'script', locations: true});
        const edits = [];
        function insert(at, text) { edits.push({at, text}); }
        function body(node) {
            if (node.type === 'BlockStatement') insert(node.start + 1, '__lilc_check();');
            else { insert(node.start, '{__lilc_check();'); insert(node.end, '}'); }
        }
        function visit(node) {
            if (!node || typeof node !== 'object') return;
            if (['WhileStatement', 'DoWhileStatement', 'ForStatement', 'ForInStatement', 'ForOfStatement'].includes(node.type)) body(node.body);
            if (['FunctionDeclaration', 'FunctionExpression', 'ArrowFunctionExpression'].includes(node.type)) {
                if (node.body.type === 'BlockStatement') {
                    const directives = node.body.body.filter(s => s.type === 'ExpressionStatement' && s.directive);
                    insert(directives.length ? directives[directives.length - 1].end : node.body.start + 1, ';__lilc_check();');
                } else { insert(node.body.start, '(__lilc_check(),'); insert(node.body.end, ')'); }
            }
            for (const key of Object.keys(node)) {
                const value = node[key];
                if (Array.isArray(value)) value.forEach(visit);
                else if (value && typeof value === 'object' && typeof value.type === 'string') visit(value);
            }
        }
        visit(ast);
        edits.sort((a,b) => b.at - a.at);
        for (const e of edits) source = source.slice(0,e.at) + e.text + source.slice(e.at);
        return source;
    }
    let ticks = 0;
    Object.defineProperty(globalThis, '__lilc_check', {value() {
        if ((++ticks & 1023) === 0 && __lilc_stopped()) throw new Error('Stopped.');
    }});
    globalThis.console = Object.freeze({log: (...v) => __lilc_write(v.map(String).join(' ')+'\n'), error: (...v) => __lilc_write(v.map(String).join(' ')+'\n'), warn: (...v) => __lilc_write(v.map(String).join(' ')+'\n')});
    globalThis.print = console.log;
    globalThis.input = (prompt = '') => { if (prompt) __lilc_write(String(prompt)); return __lilc_input(); };
    globalThis.readFile = path => __lilc_read(String(path));
    globalThis.writeFile = (path, text) => __lilc_writeFile(String(path), String(text));
    function execute(path) {
        if (cache[path]) return cache[path].exports;
        const module = {exports: {}}; cache[path] = module;
        try {
            let source;
            try { source = prepare(__lilc_read(path)); }
            catch (error) {
                if (error.loc) error.stack = path + ':' + error.loc.line + ':' + (error.loc.column + 1);
                throw error;
            }
            const parent = path.includes('/') ? path.slice(0, path.lastIndexOf('/') + 1) : '';
            const require = name => {
                if (typeof name !== 'string' || !name.startsWith('./') && !name.startsWith('../')) throw new Error('Use a local module: require(\'./module\'). Node.js/npm are unavailable.');
                return execute(__lilc_resolve(parent + name + (name.endsWith('.js') ? '' : '.js')));
            };
            compile(source, path)(require,module,module.exports);
            return module.exports;
        } catch (error) { delete cache[path]; throw error; }
    }
    // Dynamic constructors would bypass source checkpoints. Keep only the private wrapper above.
    for (const fn of [Function, (async function(){}).constructor, (function*(){}).constructor, (async function*(){}).constructor]) {
        Object.defineProperty(fn.prototype, 'constructor', {value: undefined, configurable: false, writable: false});
    }
    Object.defineProperty(globalThis, 'eval', {value: undefined, writable: false, configurable: false});
    Object.defineProperty(globalThis, 'Function', {value: undefined, writable: false, configurable: false});
    delete globalThis.acorn;
    globalThis.__lilc_run = execute;
})();
