_ = require 'lodash'
Q = require 'q'
fs = require 'fs'
path = require 'path'
crypto = require 'crypto'
less = require 'gulp-less'
sass = require('gulp-sass')(require 'sass')
marked = require 'marked'
Vinyl = require 'vinyl'
chalk = require 'chalk'
PluginError = require 'plugin-error'
through2 = require 'through2'
uglify = require 'uglify-js'
minifier = require 'gulp-minifier'
sus = require 'gulp-sus'
gulpCssSprite = require 'gulp-img-css-sprite'

EOL = '\n'
EXPORTS_REGEXP = /(^|[^.])\b(module\.exports|exports\.[^.]+)\s*=[^=]/
CSS_MODULE_HELPER = fs.readFileSync(path.join(__dirname, 'css-module-helper.js')).toString()

getUnixStylePath = (p) ->
	p.split(path.sep).join '/'

getBodyDeps = (def) ->
	deps = []
	got = {}
	def = def.replace /(^|[^.])\brequire\s*\(\s*(["'])([^"']+?)\2\s*\)/mg, (full, lead, quote, dep) ->
		pDep = dep.replace /\{\{([^{}]+)\}\}/g, quote + ' + $1 + ' + quote
		qDep = quote + pDep + quote
		got[dep] || deps.push qDep
		got[dep] = 1
		if pDep is dep
			full
		else
			lead + 'require(' + qDep + ')'
	{
		def: def
		deps: deps
	}

fixDefineParams = (def, depId, userDefinedBaseDir) ->
	def = getBodyDeps def
	bodyDeps = def.deps
	fix = (full, b, d, quote, definedId, deps) ->
		if bodyDeps.length
			if (/^\[\s*\]$/).test deps
				deps = "['require', 'exports', 'module', " + bodyDeps.join(', ') + "]"
			else if deps
				tmp = deps.replace(/'/g, '"').replace(/\s+/g, '').replace(/"\+"/g, '+')
				deps = deps.replace(/^\[\s*|\s*\]$/g, '').split(/\s*,\s*/)
				for bodyDep in bodyDeps
					if tmp.indexOf(bodyDep.replace(/'/g, '"').replace(/\s+/g, '').replace(/"\+"/g, '+')) is -1
						deps.push bodyDep
				deps = '[' + deps.join(', ') + ']'
			else
				deps = "['require', 'exports', 'module', " + bodyDeps.join(', ') + "], "
		if definedId and not (/^\./).test definedId
			id = definedId
		else
			id = depId || ''
			if id and not userDefinedBaseDir and not (/^\./).test(id)
				id = './' + id
		[b, d, id && ("'" + getUnixStylePath(id) + "', "), deps || "['require', 'exports', 'module'], "].join ''
	if not (/(^|[^.])\bdefine\s*\(/).test(def.def) and EXPORTS_REGEXP.test(def.def)
		def = [
			fix('define(', '', 'define(') + 'function(require, exports, module) {'
			def.def
			'});'
		].join EOL
	else
		def = def.def.replace /(^|[^.])\b(define\s*\()\s*(?:(["'])([^"'\s]+)\3\s*,\s*)?\s*(\[[^\[\]]*\])?/m, fix
	def

htmlBase64img = (data, base, opt) ->
	Q.Promise (resolve, reject) ->
		if opt.generateDataUri
			data = data.replace /<img\s([^>]*)src="([^"]+)"/ig, (full, extra, imgPath) ->
				if not (/^data:|\/\//i).test(imgPath)
					imgPath = path.resolve(base, imgPath)
					if fs.existsSync imgPath
						'<img ' + extra + 'src="data:image/' + path.extname(imgPath).replace(/^\./, '') + ';base64,' + fs.readFileSync(imgPath, 'base64') + '"'
					else
						full
				else
					full
			resolve data
		else
			resolve data

cssBase64img = (content, filePath, opt) ->
	Q.Promise (resolve, reject) ->
		if opt.generateDataUri
			sus.cssContent(content, filePath).then(
				(content) ->
					resolve content
				(err) ->
					reject err
			).done()
		else
			resolve content

cssSprite = (content, filePath, opt) ->
	Q.Promise (resolve, reject) ->
		if opt.cssSprite
			gulpCssSprite.cssContent(content, filePath, opt.cssSprite).then(
				(content) ->
					resolve content
				(err) ->
					reject err
			).done()
		else
			resolve content

compileLess = (file, opt) ->
	Q.Promise (resolve, reject) ->
		if opt.trace
			trace = '/* trace:' + path.relative(process.cwd(), file.path) + ' */' + EOL
		else
			trace = ''
		file._originalPath = file.path
		lessStream = less opt.lessOpt
		lessStream.pipe through2.obj(
			(file, enc, next) ->
				Q.Promise((resolve, reject) ->
					if opt.postcss
						opt.postcss(file, 'less').then (file) ->
							resolve css: file.contents.toString()
						, reject
					else
						resolve({css: file.contents.toString()})
				).then(
					(res) ->
						content = res.css
						cssSprite(content, file.path, opt).then(
							(content) ->
								cssBase64img(content, file.path, opt)
						).then(
							(content) ->
								file.contents = Buffer.from content
								minifier.minify file, minifyCSS: true
								resolve file
							(err) ->
								reject err
						).done()
					(err) ->
						reject err
				)
		)
		lessStream.on 'error', (e) ->
			console.log 'gulp-mt2amd Error:', e.message
			console.log 'file:', file.path
			console.log 'line:', e.line
		lessStream.end file

compileSass = (file, opt) ->
	Q.Promise (resolve, reject) ->
		if opt.trace
			trace = '/* trace:' + path.relative(process.cwd(), file.path) + ' */' + EOL
		else
			trace = ''
		file._originalPath = file.path
		sassStream = sass opt.sassOpt
		sassStream.on 'data', (file) ->
			Q.Promise((resolve, reject) ->
				if opt.postcss
					opt.postcss(file, 'scss').then (file) ->
						resolve css: file.contents.toString()
					, reject
				else
					resolve({css: file.contents.toString()})
			).then(
				(res) ->
					content = res.css
					cssSprite(content, file.path, opt).then(
						(content) ->
							cssBase64img(content, file.path, opt)
					).then(
						(content) ->
							file.contents = Buffer.from content
							minifier.minify file, minifyCSS: true
							resolve file
						(err) ->
							reject err
					).done()
				(err) ->
					reject err
			)
		sassStream.on 'error', (e) ->
			console.log 'gulp-mt2amd Error:', e.message
			console.log 'file:', file.path
		sassStream.write file

compileCss = (file, opt) ->
	Q.Promise (resolve, reject) ->
		if opt.trace
			trace = '/* trace:' + path.relative(process.cwd(), file.path) + ' */' + EOL
		else
			trace = ''
		file._originalPath = file.path
		Q.Promise((resolve, reject) ->
			if opt.postcss
				opt.postcss(file, 'css').then (file) ->
					resolve css: file.contents.toString()
				, reject
			else
				resolve({css: file.contents.toString()})
		).then(
			(res) ->
				content = res.css
				cssSprite(content, file.path, opt).then(
					(content) ->
						cssBase64img(content, file.path, opt)
				).then(
					(content) ->
						file.contents = Buffer.from content
						minifier.minify file, minifyCSS: true
						resolve file
					(err) ->
						reject err
				).done()
			(err) ->
				reject err
		)

compile = (file, opt, wrap) ->
	Q.Promise (resolve, reject) ->
		content = file.contents.toString()
		asyncList = []
		content = content.replace /<!--\s*include\s+(['"])([^'"]+)\.(tpl\.html|less|scss|css)\1\s*-->/mg, (full, quote, incName, ext) ->
			asyncMark = '<INC_PROCESS_ASYNC_MARK_' + asyncList.length + '>'
			incFilePath = path.resolve path.dirname(file.path), incName + '.' + ext
			incFile = new Vinyl
				base: file.base
				cwd: file.cwd
				path: incFilePath
				contents: fs.readFileSync incFilePath
			if ext is 'tpl.html'
				asyncList.push compile(incFile, opt, true)
			else if ext is 'less'
				asyncList.push compileLess(incFile, opt)
			else if ext is 'scss'
				asyncList.push compileSass(incFile, opt)
			else if ext is 'css'
				asyncList.push compileCss(incFile, opt)
			else
				return full
			asyncMark
		Q.all(asyncList).then(
			(results) ->
				htmlBase64img(content, path.dirname(file.path), opt).then(
					(content) ->
						results.forEach (incFile, i) ->
							if path.extname(incFile.path) is '.css'
								incContent = [
									'<style type="text/css">'
									incFile.contents.toString()
									'</style>'
								].join EOL
							else
								incContent = incFile.contents.toString()
							if opt.trace
								trace = '<%/* trace:' + path.relative(process.cwd(), incFile._originalPath || incFile.path) + ' */%>' + EOL
							else
								trace = ''
							content = content.replace '<INC_PROCESS_ASYNC_MARK_' + i + '>', trace + incContent
						strict = opt.strictMode or (/(^|[^.])\B\$data\./).test content
						if opt.trace
							trace = '<%/* trace:' + path.relative(process.cwd(), file.path) + ' */%>' + EOL
						else
							trace = ''
						content = [
							trace + content
						]
						if not strict
							content.unshift '<%with($data) {%>'
							content.push '<%}%>'
						if wrap
							content.unshift '<%;(function() {%>'
							content.push '<%})();%>'
						file.contents = Buffer.from content.join EOL
						resolve file
					(err) ->
						reject err
				).done()
			(err) ->
				reject err
		).done()

beautify = (content, beautifyOpt) ->
	if typeof beautifyOpt isnt 'object'
		beautifyOpt = {}
	beautifyOpt.beautify = true
	beautifyOpt.comments = ->
		true
	ast = uglify.parse content
	content = ast.print_to_string beautifyOpt

getErrorStack = (content, line) ->
	startLine = Math.max 1, line - 2
	maxLineNoLen = 0
	content = content.split(/\n|\r\n|\r/).slice startLine - 1, line + 2
	content.forEach (l, i) ->
		lineNo = (startLine + i) + (if startLine + i is line then ' ->' else '   ') + '| '
		maxLineNoLen = Math.max(maxLineNoLen, lineNo.length)
		content[i] = lineNo + l
	content.forEach (l, i) ->
		if l.split('|')[0].length + 2 < maxLineNoLen
			content[i] = ' ' + l
	content.join EOL

module.exports = (opt = {}) ->
	through2.obj (file, enc, next) ->
		return @emit 'error', new PluginError('gulp-mt2amd', 'File can\'t be null') if file.isNull()
		return @emit 'error', new PluginError('gulp-mt2amd', 'Streams not supported') if file.isStream()
		module.exports.compile(file, opt).then(
			(file) =>
				@push file
				next()
			(err) =>
				@emit 'error', new PluginError('gulp-mt2amd', err)
		).done()

module.exports.fixDefineParams = fixDefineParams

module.exports.compile = (file, opt = {}) ->
	Q.Promise (resolve, reject) ->
		originFilePath = file.path
		relativePath = path.relative process.cwd(), originFilePath
		extName = path.extname(originFilePath).toLowerCase()
		if extName is '.json'
			if opt.trace
				trace = '/* trace:' + relativePath + ' */' + EOL
			else
				trace = ''
			try
				content = JSON.parse file.contents.toString()
			catch e
				console.log chalk.red 'gulp-mt2amd Error: invalid json file ' + file.path
				throw e
			exportContent = JSON.stringify content, null, 2
			content = [
				trace + if opt.commonjs or opt.esModule then "" else "define(function(require, exports, module) {"
				if opt.esModule then "export default " + exportContent + ";" else "module.exports = " + exportContent + ";"
				if opt.commonjs or opt.esModule then "" else "});"
			].join EOL
			file.contents = Buffer.from content
			file.path = originFilePath + '.js'
			resolve file
		else if extName is '.md'
			if opt.trace
				trace = '/* trace:' + relativePath + ' */' + EOL
			else
				trace = ''
			try
				content = marked file.contents.toString(), opt.markedOptions
			catch e
				console.log chalk.red 'gulp-mt2amd Error: invalid md file ' + file.path
				throw e
			replacedSpace = if opt.conservativeCollapse then ' ' else ''
			exportContent = "'" + content.replace(/'/g, "\\'").replace(/[\r\n]/g, '\v').replace(/\s*\v\s*/g, replacedSpace) + "'"
			content = [
				trace + if opt.commonjs or opt.esModule then "" else "define(function(require, exports, module) {"
				if opt.esModule then "export default " + exportContent + ";" else "module.exports = " + exportContent + ";"
				if opt.commonjs or opt.esModule then "" else "});"
			].join EOL
			file.contents = Buffer.from content
			file.path = originFilePath + '.js'
			resolve file
		else if extName in ['.png', '.jpg', '.jpeg', '.gif', '.svg']
			if opt.trace
				trace = '/* trace:' + relativePath + ' */' + EOL
			else
				trace = ''
			exportContent = '"data:image/' + extName.replace(/^\./, '') + ';base64,' + fs.readFileSync(originFilePath, 'base64') + '"';
			content = [
				trace + if opt.commonjs or opt.esModule then "" else "define(function(require, exports, module) {"
				if opt.esModule then "export default " + exportContent + ";" else "module.exports = " + exportContent + ";"
				if opt.commonjs or opt.esModule then "" else "});"
			].join EOL
			file.contents = Buffer.from content
			file.path = originFilePath + '.js'
			resolve file
		else if extName in ['.less', '.scss', '.css']
			if extName is '.less'
				cssCompiler = compileLess
			else if extName is '.scss'
				cssCompiler = compileSass
			else
				cssCompiler = compileCss
			cssCompiler(file, opt).then(
				(file) ->
					if opt.trace
						trace = '/* trace:' + relativePath + ' */' + EOL
					else
						trace = ''
					cssContent = file.contents.toString().replace(/[\r\n]/g, '').replace(/('|\\)/g, '\\$1')
					if opt.ngStyle
						content = [
							trace + if opt.commonjs or opt.esModule then "" else "define(function(require, exports, module) {"
							if opt.esModule then "export default '" + cssContent + "';" else "module.exports = '" + cssContent + "';"
							if opt.commonjs or opt.esModule then "" else "});"
						].join EOL
						file.contents = Buffer.from content
						file.path = originFilePath + '.js'
						resolve file
						return
					if opt.cssModuleClassNameGenerator
						moduleClassName = opt.cssModuleClassNameGenerator cssContent
					else 
						moduleClassName = '_' + crypto.createHash('md5')
							.update(cssContent)
							.digest('hex')
					originalCssContent = cssContent
					cssContent = cssContent.replace new RegExp('\\.' + (opt.cssModuleClassNamePlaceholder || '__module_class_name__'), 'g'), '.' + moduleClassName
					moduleClassName = '' if cssContent is originalCssContent
					content = [
						trace + if opt.commonjs or opt.esModule then "" else "define(function(require, exports, module) {"
						if opt.useExternalCssModuleHelper then "" else CSS_MODULE_HELPER
						"var moduleUri = typeof(module) != 'undefined' && module.uri;"
						"var expo = yomCssModuleHelper('" + moduleClassName + "', '" + cssContent + "', moduleUri);"
						if opt.esModule then "__MT2AMD_ES_MODULE_EXPORT_DEFAULT__+expo;" else "module.exports = expo;"
						if opt.commonjs or opt.esModule then "" else "});"
					].join(EOL)
					if opt.beautify
						try
							content = beautify content, opt.beautify
						catch e
							console.log 'gulp-mt2amd Error:', e.message
							console.log 'file:', file.path
							console.log getErrorStack(content, e.line)
					if opt.esModule
						content = content.replace /__MT2AMD_ES_MODULE_EXPORT_DEFAULT__\s*\+\s*/g, 'export default '
					file.contents = Buffer.from content
					file.path = originFilePath + '.js'
					resolve file
				(err) ->
					reject err
			).done()
		else
			compile(file, opt).then(
				(processed) ->
					replacedSpace = if opt.conservativeCollapse then ' ' else ''
					if opt.dataInjection
						injectionObj = if typeof opt.dataInjection is 'string' then opt.dataInjection else 'window'
						dataInjection = [
							"function $injectData(name, data) {"
							"  if (typeof data === 'undefined') {"
							"    var res = [];"
							"    for (var p in name) {"
							"      if (Object.prototype.hasOwnProperty.call(name, p)) {"
							"        res.push('<script>" + injectionObj + "[\"' + p + '\"] = ' + JSON.stringify(name[p]) + ';</s' + 'cript>');"
							"      }"
							"    }"
							"    return res.join('\\n');"
							"  }"
							"  return '<script>" + injectionObj + "[\"' + name + '\"] = ' + JSON.stringify(data) + ';</s' + 'cript>';"
							"}"
						].join EOL
					content = [
						dataInjection || ""
						"function $encodeHtml(str) {"
						"  return (str + '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/\x60/g, '&#96;').replace(/\x27/g, '&#39;').replace(/\x22/g, '&quot;');"
						"}"
						"function render($data, $opt) {"
						"  $data = $data || {};"
						"  var _$out_= '" + replacedSpace + "';"
						"  var $print = function(str) {_$out_ += str;};"
						"  _$out_ += '" + processed.contents.toString().replace /<\/script>/ig, '</s<%=""%>cript>'
								.replace(/\r\n|\n|\r/g, "\v")
								.replace(/(?:^|%>).*?(?:<%|$)/g, ($0) ->
									res = $0.replace(/('|\\)/g, "\\$1")
										.replace(/\t/g, "")
										.replace(/>\v +/g, ">" + replacedSpace)
										.replace(/\v +</g, replacedSpace + "<")
										.replace(/\v+/g, replacedSpace)
										.replace(/ +/g, " ")
									res = res.replace(/(^|%>) /, "$1") if not (/(?:^|%>) *(?:<%|$)/.test(res))
									res
								)
								.replace(/[\v]/g, EOL)
								.replace(/<%==([\s\S]*?)%>/mg, "' + $encodeHtml($1) + '")
								.replace(/<%=([\s\S]*?)%>/mg, "' + ($1) + '")
								.replace(/<%(<-)?/g, "';" + EOL + "  ")
								.replace(/->(\w+)%>/g, EOL + "  $1 += '")
								.split("%>").join(EOL + "  _$out_ += '") + "';"
						"  return _$out_;"
						"}"
					].join(EOL).replace(/_\$out_ \+= ' *';/g, '')
					file.contents = Buffer.from content
					file.path = file.path + '.js'
					Q.Promise((resolve, reject) ->
						if opt.babel
							opt.babel(file).then(resolve, reject)
						else
							resolve file
					).then(
						(file) ->
							content = file.contents.toString()
							if not opt.commonjs and not opt.esModule
								content = "define(function(require, exports, module) {" + EOL + content
							if opt.esModule
								content += EOL + "__MT2AMD_ES_MODULE_EXPORT_DEFAULT__+{render: render};"
							else
								content += EOL + "exports.render = render;"
							if not opt.commonjs and not opt.esModule
								content += EOL + "});"
							content = fixDefineParams content if not opt.commonjs
							if opt.beautify
								try
									content = beautify content, opt.beautify
								catch e
									console.log 'gulp-mt2amd Error:', e.message
									console.log 'file:', file.path
									console.log getErrorStack(content, e.line)
							if opt.esModule
								content = content.replace /__MT2AMD_ES_MODULE_EXPORT_DEFAULT__\s*\+\s*/g, 'export default '
							file.contents = Buffer.from content
							resolve file
						reject
					)
				reject
			).done()
