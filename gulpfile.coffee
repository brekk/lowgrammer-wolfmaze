_ = require 'lodash'
gulp = require 'gulp'
utility = require 'gulp-util'
coffee = require 'gulp-coffee'
watch = require 'gulp-watch'
plumber = require 'gulp-plumber'
clean = require 'gulp-clean'
uglify = require 'gulp-uglify'
concat = require 'gulp-concat'
browserify = require 'browserify'
download = require 'gulp-download'
flatten = require 'gulp-flatten'
source = require 'vinyl-source-stream'
stylus = require 'gulp-stylus'
prefix = require 'gulp-autoprefixer'
minicss = require 'gulp-minify-css'
# yuidoc = require 'gulp-yuidoc'
mocha = require 'gulp-mocha'

jshint = require 'gulp-jshint'
stylish = require 'jshint-stylish'

newer = require 'gulp-newer'

cson = require 'cson'
fs = require 'fs'

promise = require 'promised-io'
Deferred = promise.Deferred

currentDirectory = process.cwd()
scaffoldPath = currentDirectory + '/config/scaffold.json'

scaffold = require scaffoldPath

process.on 'uncaughtException', (finalError)->
    if !_.isNull finalError
        console.log "Error during gulping:", finalError

# pipes, hoses and plumbers, oh my!
hose = (source, dest=null, addFx=null, watch=false, options=null)->
    lengthOfArguments = _.toArray(arguments).length
    if lengthOfArguments is 3
        if _.isNull(watch)
            if _.isBoolean(addFx)
                watch = true
    sluice = null
    # add source options if given
    if options?.source? and lengthOfArguments is 5
        sluice = gulp.src(source, options.source)
    else
        sluice = gulp.src(source)
    # make it a watcher
    if watch
        sluice.pipe(watch())
              .pipe(plumber())
    else
        if _.isFunction addFx
            addFx sluice
        else if _.isArray addFx
            _.each addFx, (addFunctionTo)->
                if _.isFunction addFunctionTo
                    addFunctionTo sluice
                return
    if _.isNull dest
        return sluice.on 'error', utility.log
    else
        return sluice.on('error', utility.log)
                     .pipe gulp.dest dest

# *  gulp move - move some of the plumbing files around
#    -  gulp move:modules
#    -  gulp move:tmp
#    -  gulp move:docs

gulp.task 'move:modules:nib', ()->
    gulp.src(['./node_modules/nib/lib/**/*.*'], {base: './node_modules/nib'})
        .pipe gulp.dest './src/css'

gulp.task 'move:modules:test:js', ()->
    gulp.src([
            './node_modules/mocha/mocha.js'
            './node_modules/should/should.js'
        ])
        .pipe gulp.dest './build/public/js/'

gulp.task 'move:modules:test:css', ()->
    gulp.src([
            './node_modules/mocha/mocha.css'
        ])
        .pipe gulp.dest './build/public/css/'

gulp.task 'move:modules:test', [
    'move:modules:test:js'
    'move:modules:test:css'
]

gulp.task 'move:modules', [
    'move:modules:nib'
    'move:modules:test'
]

# depending on the build task it is often useful
# to not have to traverse all of the folders in src
# so this task flattens the coffee files into /tmp
gulp.task 'move:tmp', ()->
    hose scaffold.paths.source.coffee, './tmp', (sluice)->
        return sluice.pipe flatten()

gulp.task 'move', [
    'move:modules'
    'move:tmp'
]

# *  gulp convert - convert source to a deployable format
#    -  gulp convert:coffee
#    -  gulp convert:stylus

gulp.task 'convert:coffee', ()->
    destination = './build'
    hose scaffold.paths.source.coffee, destination, (sluice)->
        return sluice.pipe(coffee())
                     .pipe flatten()

gulp.task 'convert:stylus', ['move'], ()->
    destination = './build/public/css'
    gulp.src(scaffold.paths.source.stylus)
        .pipe(newer(destination))
        .pipe(stylus())
        .pipe(prefix())
        .pipe gulp.dest destination

gulp.task 'convert', [
    'convert:coffee'
    'convert:stylus'
]

# *  gulp auto - automatic testing, building and checking
#    -  gulp auto:doc
#    -  gulp auto:test
#    -  gulp auto:check

gulp.task 'auto:doc:coffee', ()->
    gulp.src(scaffold.paths.documentation)
        .pipe(coffee())
        .pipe(flatten())
        .pipe gulp.dest './tmp/docs'
    return

gulp.task 'auto:doc', ['auto:doc:coffee'], ()->
    d = new Deferred()
    gulp.src('./tmp/docs/*.js')
        .pipe(yuidoc())
        .pipe gulp.dest './build/public/docs'
    (->
        d.resolve true
    )()
    return d

# *  gulp download - download source content
#    -  gulp download:vendor
#    -  gulp download:assets

# use the scaffold file to generate download tasks
makeDownloadable = (x)->
    if x? and _.isString x
        gulp.task "download:#{x}", ()->
            # pull-down #{x} files
            if scaffold?[x]?
                files = scaffold[x]
                sluice = download(files).pipe gulp.dest("./#{x}")

# make downloadables
makeDownloadable 'vendor'
makeDownloadable 'assets'

gulp.task 'download', [
    'download:vendor'
    'download:assets'
]

# *  gulp watch
#    -  gulp watch:coffee
#    -  gulp watch:stylus

gulp.task 'watch:coffee', ()->
    gulp.watch scaffold.paths.source.coffee, ['convert:coffee', 'clean:src:js', 'build']

gulp.task 'watch:and:test:coffee', ()->
    gulp.watch scaffold.paths.source.coffee, ['convert:coffee', 'clean:src:js', 'build', 'auto']

gulp.task 'watch:stylus', ()->
    gulp.watch scaffold.paths.source.stylus, ['convert:stylus', 'build']

# *  gulp clean - get rid of files or folders (or everything)

makeCleanTask = (name, path, prior=[])->
    if _.toArray(arguments).length is 1
        path = name
    makeCleaner = (op=true)->
        if op
            return ()->
                if _.isString path
                    path = './' + path
                    hose path, null, (sluice)->
                        return sluice.pipe clean()
                    , false, {read: false}

        return ()->
    if prior.length > 0
        gulp.task "clean:#{name}", prior, makeCleaner false
    else
        gulp.task "clean:#{name}", makeCleaner true

# make some cleaners
cleanables = [
    'assets'
    'build'
    'data'
    'dist'
    'vendor'
    'tools'
    'test'
    'tmp'
    'node_modules'
    'gulpfile.js'
]
_(cleanables).each (path)->
    makeCleanTask path

makeCleanTask 'tmp:docs', 'tmp/docs'

makeCleanTask 'wipe', _.map cleanables, (x)->
    return "clean:#{x}"

gulp.task 'clean:src:js', ()->
    gulp.src([
            './src/coffee/*.js'
            './src/coffee/*/*.js'
        ], {read: false})
        .pipe clean()

gulp.task 'clean:dev', [
    'clean:build'
    'clean:src:js'
    'clean:tmp'
    'clean:test'
    'clean:gulpfile.js'
]

gulp.task 'clean', [
    'clean:wipe'
]

gulp.task 'wipe', [
    'clean:wipe'
]

# *  gulp build - build our content
#    -  gulp build:client
#    -  gulp build:dist
#    -  gulp build:dist
#    -  gulp build:tools

gulp.task 'build:client:js', ['move:tmp'], ()->
    bundler = browserify()
    bundler.add('./tmp/client.coffee')
           .transform('coffeeify')
           .bundle()
           .on('error', (err)->
               console.log err.toString()
               this.emit 'end'
           )
           .pipe(source('./ww.js'))
           .pipe gulp.dest './build/client'

gulp.task 'build:client:readme', ['move:tmp'], ()->
    bundler = browserify()
    bundler.add('./tmp/readme.coffee')
           .transform('coffeeify')
           .bundle()
           .on('error', (err)->
               console.log err.toString()
               this.emit 'end'
           )
           .pipe(source('./readme.js'))
           .pipe gulp.dest './build/client'

gulp.task 'build:client', ['build:client:js', 'build:client:readme'], ()->
    gulp.src([
            './build/client/ww.js'
            './build/client/browser-build.js'
            './build/client/readme.js'
            './build/realtime.js'
        ])
        .pipe gulp.dest './build/public/js'

gulp.task 'build:test:server', ()->
    hose [
        './src/coffee/test/*.coffee'
    ], './test', (sluice)->
        # .pipe(flatten())
        return sluice.pipe coffee({bare: true})

gulp.task 'build:test:client', ['move:modules:test'], ()->
    hose [
        './src/coffee/client/client-test-harness.coffee'
    ], './build/public/js', (sluice)->
        # .pipe(flatten())
        return sluice.pipe coffee({bare: true})

gulp.task 'build:test', [
    'build:test:server'
    'build:test:client'
]

gulp.task 'auto:test', [
    'convert:coffee'
    'build:test'
], ()->
    gulp.src('test/spec-*.js')
        .pipe mocha {
            reporter: 'spec'
        }

gulp.task 'auto:check', [
    'convert:coffee'
], ()->
    gulp.src('./build/*.js')
        .pipe(jshint({
            eqnull:true
            boss:true
        }))
        .pipe(jshint.reporter(stylish))

gulp.task 'auto', [
    'auto:test'
    'auto:check'
    # 'auto:doc'
]

gulp.task 'build:tools', [
    'convert:coffee'
], ()->
    gulp.src('./build/corndog-cli.js')
        .pipe(flatten())
        .pipe gulp.dest './tools'

gulp.task 'build', [
    'convert'
    'build:client'
    'build:test'
]

gulp.task 'default', [
    'build'
    'auto'
]
