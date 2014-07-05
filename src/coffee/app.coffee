"use strict"

_ = require 'lodash'
express = require 'express.io'
http = require 'http'
prettyHTML = require('js-beautify').html
stylus = require 'stylus'
fs = require 'fs'
path = require 'path'
markdown = require('markdown').markdown
useragent = require 'express-useragent'
promise = require 'promised-io/promise'
Deferred = promise.Deferred
cheerio = require 'cheerio'
slug = require 'slug'
request = require 'request'

process.on "uncaughtException", (finalError)->
    if !_.isNull finalError
        console.warn "MEGA ERROR", finalError.stack, finalError.msg
        throw finalError

currentDirectory = process.cwd()

config = {
    title: 'Wolfmaze'
    env: "development"
    port: process.env.PORT or 8888
    # The relevant directories
    directories: {
        root: currentDirectory
        # all directories get prepended with directories.root @ runtime
        public: '/build/public'
        build: '/build'
        docs: '/build/public/docs'
        views: '/views'
        vendor: '/vendor'
        assets: '/assets'
    }
    constants: { 
        SECRET : '98hsklg9h4pao3i7g4PJUp9gsDKsii7s7362o4hyFt9'
        KEY : 'a0sdgJ434LKsDyJOIsdJH44L4KtELyL8O9OWdIsS3'
        COOKIE_LIFETIME : 1800000 # ms: 1 min = 60000
    }
}

directories = {}

root = config.directories.root
views = config.directories.views
directories.views = root + '' + views
directories.vendor = root + '' + config.directories.vendor
directories.public = root + '' + config.directories.public
directories.assets = root + '' + config.directories.assets

app = express().http().io()

app.set 'env', config.env
app.set 'views', directories.views
app.set 'view engine', 'jade'

# makes useragent data available in requests
app.use useragent.express()

# serve our directories.public as a static directory
app.use express.static directories.public

# default middleware
app.use express.cookieParser()
app.use express.json()
app.use express.urlencoded()

# session data
app.use express.session {
    cookie: {
        maxAge: config.constants.COOKIE_LIFETIME
    }
    secret: config.constants.SECRET
    key: config.constants.KEY
}

show404 = (req, res, error)->
    options = {
        url: req.url
    }
    options.info = "The page you requested (<em>#{options.url}</em>) doesn't exist."
    if error
        console.log req.method, req.url, error
        options.info = "The page you requested (<em>#{options.url}</em>) threw an error:"
        options.error = error
    res.render '404', options, (err, html)->
        if err
            res.send 500, err
            return
        res.send html
        return

app.use app.router

app.use (req, res, next)->
    show404(req, res)

app.use (err, req, res, next)->
    if err
        console.log "final error stack!", err.stack
        res.send 500, "The machine is sick."

app.locals {
    title: config.title
}

menuRoutes = []

hasMenuRoute = (routeName)->
    _(menuRoutes).filter((menuRoute)->
        return menuRoute.route is routeName
    ).value().length > 0

routeRegistrar = (route, kind, source)->
    allowedKinds = 'jade|html|md|build|api'
    unless _.isString route
        throw new TypeError "Expected route to be string."
    if kind is 'build' and arguments.length is 2
        source = route
    unless _.isString kind
        throw new TypeError "Expected kind to be string."
    unless _.isString source
        throw new TypeError "Expected source to be string."
    unless _.contains allowedKinds.split('|'), kind
        throw new Error "Expected kind to be one of #{allowedKinds}"
    unless hasMenuRoute route
        menuRoutes.push {
            route: route
            kind: kind
            source: source
        }

writeAStaticPage = (url, view, stuff=false, outputLocation=false, requestResponse=null)->
    # register our route for menu making later
    routeRegistrar url, 'jade', view
    app.get url, (req, res)->
        if requestResponse?
            unless _.isFunction requestResponse
                throw new TypeError "Expected requestResponse to be a function."
            else
                {req, res} = requestResponse req, res
        options = {
            layout: false
        }
        if _.isObject stuff
            _(stuff).keys().each (key)->
                options[key] = stuff[key]
        res.render view, options, (err, html)->
            if err
                show404 req, res, err
                return
            if outputLocation
                phil.write outputLocation, prettyHTML(html), ()->
                    console.log "Wrote static HTML content to #{outputLocation}."
                    res.send html
            return

makeAnEndpoint = (url, view, stuff=false, requestResponse=null)->
    # register our route
    routeRegistrar url, 'jade', view
    app.get url, (req, res)->
        if requestResponse?
            unless _.isFunction requestResponse
                throw new TypeError "Expected requestResponse to be a function."
            else
                {req, res} = requestResponse req, res
        options = {
            layout: false
        }
        displayFailures = false
        if _.isObject stuff
            _(stuff).keys().each (key)->
                if key is 'showfail'
                    displayFailures = true
                else
                    options[key] = stuff[key]
        res.render view, options, (err, html)->
            if err
                if !displayFailures
                    show404 req, res, err
                else
                    console.log err, "Error during page render."
                    throw err
                return
            res.send html
            return

htmlEndpoint = (url, view, requestResponse=null)->
    # register our route
    routeRegistrar url, 'html', view
    app.get url, (req, res)->
        if requestResponse?
            unless _.isFunction requestResponse
                throw new TypeError "Expected requestResponse to be a function."
            else
                {req, res} = requestResponse req, res
        fs.readFile view, 'utf8', (err, html)->
            if err
                console.log err
                throw err
            res.send html
            return
        return

markdownEndpoint = (url, file, transformFunction, requestResponse=null)->
    # register our route
    routeRegistrar url, 'md', file
    # if we don't get a tranformFunction, make a simple pass-through
    unless transformFunction?
        transformFunction = (html, cb)->
            return cb html
    if requestResponse?
        unless _.isFunction requestResponse
            throw new TypeError "Expected requestResponse to be a function."
    app.get url, (req, res)->
        if requestResponse?
            {req, res} = requestResponse req, res
        fs.readFile file, 'utf8', (err, html)->
            if err
                console.log err
                throw err
            transformFunction markdown.toHTML(html), (transformed)->
                res.send transformed
            return
        return
    return

lowerSlug = (x)->
    if _.isString x
        text = slug(x).toLowerCase()
        parts = text.split('-')
        if parts.length > 5
            parts = parts.slice 0, 5
            text = parts.join('-')
        return text

autoMarkdown = (title, stylesheet, transform=null)->
    unless _.isString title
        throw new TypeError "Expected title to be string."
    unless _.isString stylesheet
        throw new TypeError "Expected stylesheet to be string."
    if transform?
        unless _.isFunction transform
            throw new TypeError "Expected transform to be function or null."
    return (html, cb)->
        unless html?
            throw new Error "Expected html not to be null."
        unless _.isFunction cb
            throw new TypeError "Expected callback to be function."
        $ = cheerio.load("""
            <!DOCTYPE html>
            <html lang="en">
                <head>
                    <title>#{title}</title>
                </head>
                <body>
                </body>
            </html>
        """)

        sheet = $('<link>').attr('id', 'readme-style')
                                .attr('type', 'text/css')
                                .attr('rel', 'stylesheet')
                                .attr 'href', stylesheet

        $('head').append sheet
        $('body').html html
        # support typekit
        typekit = $('<script>').attr('type', 'text/javascript')
                               .attr 'src', '//use.typekit.net/yzk1lcg.js'

        typekit2 = $('<script>').attr('type', 'text/javascript')
                                .html 'try{Typekit.load();}catch(e){}'
        # browser build
        bundle = $('<script>').attr('type', 'text/javascript')
                              .attr('src', './js/readme.js')

        $('body').append(bundle)
                 .append(typekit)
                 .append(typekit2)

        if transform?
            $ = transform $

        return cb $.html()

nearestFiveMinuteTimestamp = ()->
    d = new Date()
    prependZeroes = (s)->
        s = '' + s
        if s.length is 1
            return '0' + s
        return s
    month = prependZeroes d.getMonth()
    date = prependZeroes d.getDate()
    year = d.getFullYear()
    hours = prependZeroes d.getHours()
    minutes = d.getMinutes()
    closest5 = _([0..12]).map((x)->
        return x * 5
    ).filter((x)->
        return x <= minutes
    ).last()
    closest5 = prependZeroes closest5
    time = "#{month}#{date}#{year}-#{hours}#{closest5}"
    return time

markdownEndpoint '/', './README.md', autoMarkdown 'Visualized - Read Me', './css/readme.css', ($)->
    # menu magic
    menuify = ()->
        current = $(@)
        text = current.text()
        if current.find('ol, ul').length == 0
            current.text ''
            url = lowerSlug(text)
            link = $('<a>').attr('href', '#'+url)
                           .text(text)
            current.append link
        else
            innerLists = current.find('ul')
            childHTML = innerLists.html()
            childText = innerLists.text()
            current.html ''
            text = text.substr(0, text.indexOf(childText))
            url = lowerSlug(text)
            link = $('<a>').attr('href', '#'+url)
                           .text(text)
            current.append link
            current.append $('<ul>').html childHTML
            current.find('li').each menuify

    $('ol').eq(0).find('li').each menuify

    # convert given selectors' text content to ids
    slugify = ()->
        current = $(@)
        text = lowerSlug current.text()
        current.attr 'id', text
    # slugify all titles
    $('h1, h2, h3, h4, h5, h6').each slugify
    return $
    
markdownEndpoint '/todo', './TODO.md', autoMarkdown('Visualized - To Do', './css/readme.css')

# register some additional routes that aren't transparently part of the server
routeRegistrar '/docs', 'build'

console.log "Available routes:"
_.each menuRoutes, (page)->
    if page.kind isnt 'api'
        console.log "    * #{page.source} (#{page.kind}) @ localhost:#{config.port}#{page.route}"
    else
        console.log "    * API Route: #{page.route} @ localhost:#{config.port}#{page.route}"

console.log "Running a server on localhost:#{config.port}"
app.listen config.port
module.exports = app