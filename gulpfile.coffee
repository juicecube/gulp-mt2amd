crypto = require 'crypto'
gulp = require 'gulp'
coffee = require 'gulp-coffee'
postcss = require 'postcss'
postcssImport = require 'postcss-import'
autoprefixer = require 'autoprefixer'
imgCssSprite = require 'gulp-img-css-sprite'

gulp.task 'copy', ->
	gulp.src('src/**/*.js')
		.pipe gulp.dest('lib')

gulp.task 'compile', ->
	gulp.src('src/**/*.coffee')
		.pipe coffee()
		.pipe gulp.dest('lib')

gulp.task 'sprite', ->
	gulp.src('example/src/**/*.+(jpg|png)')
		.pipe imgCssSprite.imgStream
			padding: 2
		.pipe gulp.dest('example/dest')

gulp.task 'example', gulp.series 'sprite', ->
	mt2amd = require './lib/index'
	gulp.src(['example/src/**/*.json', 'example/src/**/*.md', 'example/src/**/*.tpl.html', 'example/src/**/*.css', 'example/src/**/*.less', 'example/src/**/*.scss', 'example/src/**/*.+(png|jpg|jpeg|gif|svg)'])
		.pipe mt2amd
			conservativeCollapse: false
			generateDataUri: true
			cssSprite:
				base:
					url: '//webyom.org'
					dir: 'example/src'
			beautify: true
			trace: true
			cssModuleClassNameGenerator: (css) ->
				'module-' + crypto.createHash('md5')
					.update(css)
					.digest('hex')
					.slice(0, 8)
			cssModuleClassNamePlaceholder: '___module_class_name___'
			useExternalCssModuleHelper: false
			postcss: (file, type) ->
				postcss([postcssImport(), autoprefixer()])
					.process file.contents.toString(),
						from: file.path
					.then (res) ->
						file.contents = Buffer.from res.css
						file
			markedOptions:
				smartypants: true
				langPrefix: 'lang-'
		.pipe gulp.dest('example/dest')

gulp.task 'default', gulp.parallel 'copy', 'compile'
