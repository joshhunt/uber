fs = require 'fs'
path = require 'path'

Handlebars = require 'handlebars'

writeToFile = (filename, data) ->
    filename = filename
    fs.writeFile filename, data, ->

trips = require './tmp/uberRideStats.json'
templateHTML = fs.readFileSync './map.hbs', 'utf-8'
template = Handlebars.compile templateHTML
page = template {uberTrips: JSON.stringify trips}
writeToFile 'map.html', page