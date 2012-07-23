fs = require 'fs'
path = require 'path'
{concat, foldl} = require './functional-helpers'
{Preprocessor} = require './preprocessor'
{Optimiser} = require './optimiser'
parser = require './parser'
cscodegen = try require 'cscodegen'
escodegen = try require 'escodegen'
uglifyjs = try require 'uglify-js'

inspect = (o) -> (require 'util').inspect o, no, 9e9, yes

cleanMarkers = (str) -> str.replace /\uEFEF|\uEFFE\uEFFF/g, ''

humanReadable = (str) ->
  (str.replace /\uEFEF/g, '(INDENT)').replace /\uEFFE\uEFFF/g, '(DEDENT)'

numberLines = (input, startLine = 1) ->
  lines = input.split '\n'
  padSize = ((lines.length + startLine - 1).toString 10).length
  numbered = for line, i in lines
    currLine = "#{i + startLine}"
    pad = (Array(padSize + 1).join '0')[currLine.length..]
    "#{pad}#{currLine} : #{lines[i]}"
  numbered.join '\n'

printParserError = (e) ->
  if e.found?
    line = (input.split '\n')[e.line - 1]
    e.column = (cleanMarkers ("#{line}\n").slice 0, e.column).length
  console.error humanReadable """
    Syntax error on line #{e.line}, column #{e.column}: unexpected #{if e.found? then inspect e.found else 'end of input'}
    """
  if e.found?
    console.error cleanMarkers line
    console.error "#{(Array e.column).join '-'}^"


# clone args
args = process.argv[1 + (process.argv[0] is 'node') ..]

# ignore args after --
additionalArgs = []
if '--' in args then additionalArgs = args.splice (args.indexOf '--'), 9e9


# initialise options
options = {}
optionMap = {}

optionArguments = [
  [['parse',   'p'], off, 'output a JSON-serialised AST representation of the input']
  [['compile', 'c'], off, 'output a JSON-serialised AST representation of the output']
  [['optimise'    ],  on, 'enable optimisations (default: on)']
  [['debug'       ], off, 'output intermediate representations on stderr for debug']
  [['version', 'v'], off, 'display the version number']
  [['help'        ], off, 'display this help message']
]

parameterArguments = [
  [['cli'         ], 'INPUT', 'pass a string from the command line as input']
  [['input',   'i'], 'FILE' , 'file to be used as input instead of STDIN']
  [['nodejs'      ], 'OPTS' , 'pass options through to the node binary']
  [['output',  'o'], 'FILE' , 'file to be used as output instead of STDIN']
  [['watch',   'w'], 'FILE' , 'watch the given file/directory for changes']
]

if escodegen?
  [].push.apply optionArguments, [
    [['bare',    'b'], off, 'omit the top-level function wrapper']
    [['js',      'j'], off, 'generate JavaScript output']
    [['eval',    'e'], off, 'evaluate compiled JavaScript']
    [['repl'        ], off, 'run an interactive CoffeeScript REPL']
  ]
  if uglifyjs?
    optionArguments.push [['minify',  'm'], off, 'run compiled javascript output through a JS minifier']
  parameterArguments.push [['require', 'I'], 'FILE' , 'require a library before a script is executed']

if cscodegen?
  optionArguments.push [['cscodegen', 'f'], off, 'output cscodegen-generated CoffeeScript code']


shortOptionArguments = []
longOptionArguments = []
for opts in optionArguments
  options[opts[0][0]] = opts[1]
  for o in opts[0]
    optionMap[o] = opts[0][0]
    if o.length is 1 then shortOptionArguments.push o
    else if o.length > 1 then longOptionArguments.push o

shortParameterArguments = []
longParameterArguments = []
for opts in parameterArguments
  for o in opts[0]
    optionMap[o] = opts[0][0]
    if o.length is 1 then shortParameterArguments.push o
    else if o.length > 1 then longParameterArguments.push o


# define some regexps that match our arguments
reShortOptions = ///^ - (#{shortOptionArguments.join '|'})+ $///
reLongOption = ///^ -- (no-)? (#{longOptionArguments.join '|'}) $///
reShortParameter = ///^ - (#{shortParameterArguments.join '|'}) $///
reLongParameter = ///^ -- (#{longParameterArguments.join '|'}) $///
reShortOptionsShortParameter = ///
  ^ - (#{shortOptionArguments.join '|'})+
  (#{shortParameterArguments.join '|'}) $
///


# parse arguments
positionalArgs = []
while args.length
  arg = args.shift()
  if reShortOptionsShortParameter.exec arg
    args.unshift "-#{arg[1...-1]}", "-#{arg[-1..]}"
  else if reShortOptions.exec arg
    for o in arg[1..].split ''
      options[optionMap[o]] = on
  else if match = reLongOption.exec arg
    options[optionMap[match[2]]] = if match[1]? then off else on
  else if match = (reShortParameter.exec arg) ? reLongParameter.exec arg
    options[optionMap[match[1]]] = args.shift()
  else
    positionalArgs.push arg


# input validation

unless options.compile or options.js or options.parse or options.eval or options.cscodegen
  if not escodegen?
    options.compile = on
  else if positionalArgs.length
    options.eval = on
    options.input = positionalArgs.shift()
    additionalArgs = [positionalArgs..., additionalArgs...]
  else
    options.repl = on

# mutual exclusions
# - p (parse), c (compile), j (js), e (eval), cscodegen, repl
if 1 isnt options.parse + options.compile + (options.js ? 0) + (options.eval ? 0) + (options.cscodegen ? 0) + (options.repl ? 0)
  console.error "Error: At most one of --parse (-p), --compile (-c), --js (-j), --eval (-e), --cscodegen, or --repl may be used."
  process.exit 1

# - i (input), w (watch), cli
if 1 < options.input? + options.watch? + options.cli?
  console.error 'Error: At most one of --input (-i), --watch (-w), or --cli may be used.'
  process.exit 1

# dependencies
# - I (require) depends on e (eval)
if options.require? and not options.eval
  console.error 'Error: --require (-I) depends on --eval (-e)'
  process.exit 1

# - m (minify) depends on escodegen and uglifyjs and (c (compile) or e (eval))
if options.minify and not (options.compile or options.eval)
  console.error 'Error: --minify does not make sense without --compile or --eval'
  process.exit 1

# - b (bare) depends on escodegen and (c (compile) or e (eval)
if options.bare and not (options.compile or options.eval)
  console.error 'Error: --bare does not make sense without --compile or --eval'
  process.exit 1

# - i (input) depends on o (output) when input is a directory
if options.input? and (fs.statSync options.input).isDirectory() and (not options.output? or (fs.statSync options.output)?.isFile())
  console.error 'Error: when --input is a directory, --output must be provided, and --output must not reference a file'

# - cscodegen depends on cscodegen
if options.cscodegen and not cscodegen?
  console.error 'Error: cscodegen must be installed to use --cscodegen'
  process.exit 1


# start processing options
if options.help
  $0 = if process.argv[0] is 'node' then process.argv[1] else process.argv[0]
  $0 = path.basename $0
  maxWidth = 85

  wrap = (lhsWidth, input) ->
    rhsWidth = maxWidth - lhsWidth
    pad = (Array lhsWidth + 4 + 1).join ' '
    rows = while input.length
      row = input[...rhsWidth]
      input = input[rhsWidth..]
      row
    rows.join "\n#{pad}"

  formatOptions = (opts) ->
    opts = for opt in opts
      switch opt.length
        when 0 then continue
        when 1 then "-#{opt}"
        else "--#{opt}"
    opts.sort (a, b) -> a.length - b.length
    opts.join ', '

  console.log """
    Usage:
      #{$0} FILE ARG* [-- ARG*]
      #{$0} OPT* [--repl] OPT*
      #{$0} OPT* -{-parse,p,-compile,c,-js,j,-cscodegen} OPT*
      #{$0} {OPT,ARG}* -{-eval,e} {OPT,ARG}* -- ARG*

  """

  optionRows = for opt in optionArguments
    [(formatOptions opt[0]), opt[2]]
  parameterRows = for opt in parameterArguments
    ["#{formatOptions opt[0]} #{opt[1]}", opt[2]]
  leftColumnWidth = foldl 0, [optionRows..., parameterRows...], (memo, opt) ->
    Math.max memo, opt[0].length

  rows = [optionRows..., parameterRows...]
  rows.sort (a, b) ->
    a = a[0]; b = b[0]
    if a[0..1] is '--' and b[0..1] isnt '--' then return 1
    if b[0..1] is '--' and a[0..1] isnt '--' then return -1
    if a.toLowerCase() < b.toLowerCase() then -1 else 1
  for row in rows
    console.log "  #{row[0]}#{(Array leftColumnWidth - row[0].length + 1).join ' '}  #{wrap leftColumnWidth, row[1]}"

  console.log """

    Unless instructed otherwise (--{input,watch,cli}), `#{$0}` will operate on stdin/stdout.
    When none of -{-parse,p,-compile,c,-js,j,-eval,e,-cscodegen,-repl} are given
      If positional arguments were given
        * --eval is implied
        * the first positional argument is used as an input filename
        * additional positional arguments are passed as arguments to the script
      Else --repl is implied
  """

else if options.version
  filename = path.join __dirname, '..', '..', 'package.json'
  fs.readFile filename, (err, pkg) ->
    throw err if err
    console.log "CoffeeScript version #{(JSON.parse pkg).version}"

else if options.repl
  # TODO: start repl
  console.log 'TODO: REPL'

else
  # normal workflow

  input = ''

  processInput = (err) ->

    throw err if err?
    result = null

    # preprocess
    try input = Preprocessor.processSync input
    catch e
      console.error (e.stack or e.message)
      process.exit 1

    if options.debug
      console.error '### PREPROCESSED ###'
      console.error numberLines humanReadable input.trim()

    # parse
    try result = parser.parse input
    catch e
      throw e unless e instanceof parser.SyntaxError
      printParserError e
      process.exit 1

    if options.debug and options.optimise and result?
      console.error '### PARSED ###'
      console.error inspect result.toJSON()

    # optimise
    if options.optimise and result?
      optimiser = new Optimiser
      try result = optimiser.optimise result
      catch e
        console.error (e.stack || e.message)
        process.exit 1

    # --parse
    if options.parse
      if result?
        console.log inspect result.toJSON()
        process.exit 0
      else process.exit 1

    if options.debug and result?
      console.error "### #{if options.optimise then 'OPTIMISED' else 'PARSED'} ###"
      console.error inspect result.toJSON()

    # cs code gen
    if options.cscodegen
      try result = cscodegen.generate result
      catch e
        console.error (e.stack || e.message)
        process.exit 1
      if result?
        console.log result
        process.exit 0
      else process.exit 1

    # compile
    try
      throw new Error 'compilation not implemented yet'
      compiler = new Compiler
      result = compiler.compile result
    catch e
      console.error (e.stack || e.message)
      process.exit 1

    # --compile
    if options.compile
      if result?
        console.log inspect result.toJSON()
        process.exit 0
      else process.exit 1

    # js code gen
    try
      result = escodegen.generate result
        format:
          indent:
            style: '  '
            base: 0
          renumber: yes
          hexadecimal: yes
          quotes: 'auto'
          parentheses: no
      if options.minify and result?
        result = uglifyjs.uglify.gen_code uglifyjs.uglify.ast_squeeze uglifyjs.uglify.ast_mangle uglifyjs.parser.parse result
    catch e
      console.error (e.stack || e.message)
      process.exit 1

    # --js
    if options.js
      if result?
        console.log inspect result.toJSON()
        process.exit 0
      else process.exit 1

    # --eval
    if options.eval
      do -> (0; eval) result


  # choose input source

  if options.input?
    # TODO: handle directories
    fs.readFile options.input, (err, contents) ->
      throw err if err?
      input = contents
      do processInput
  else if options.watch?
    # TODO: watch
  else if options.cli?
    input = options.cli
    do processInput
  else
    process.stdin.on 'data', (data) -> input += data
    process.stdin.on 'end', processInput
    process.stdin.setEncoding 'utf8'
    do process.stdin.resume