fs = require 'fs'
path = require 'path'
url = require 'url'

_ = require 'underscore'
async = require 'async'
request = require 'request'
cheerio = require 'cheerio'
moment = require 'moment'

request = request.defaults {jar: true}

CONCURRENCY = 3
LOGIN_URL = 'https://www.uber.com/log-in'
config = require './config.json'

CAR_MAP =
    'uberx': 'UberX'
    'suv': 'UberSUV'
    'black': 'UberBlack'
    'uberblack': 'UberBlack'
    'taxi': 'Taxi'

writeToFile = (filename, data) ->
    filename = path.join 'tmp', filename
    fs.writeFile filename, data, ->

console.log 'Requesting loging page...'
request LOGIN_URL, (err, res, body) ->
    $ = cheerio.load body
    csrf = $('[name=x-csrf-token]').val()
    login config.username, config.password, csrf

login = (user, pass, csrf) ->
    form =
        'login': user
        'password': pass
        'x-csrf-token': csrf
        'redirect_to': 'riders'
        'redirect_url': 'https://riders.uber.com/trips'
        'request_source': 'www.uber.com'

    console.log 'Logging in...'
    request.post LOGIN_URL, {form}, (err, res, body) ->
        throw err if err
        resp = JSON.parse(body)

        throw new Error resp.error  if resp.error

        redirectUrl = resp['redirect_to']
        request redirectUrl, (err) ->
            throw err if err
            startParsing()

requestTripList = (page, cb) ->
    listUrl = "https://riders.uber.com/trips?page=#{page}"
    options =
        url: listUrl
        headers: 'x-ajax-replace': true
    console.log 'Fetching', listUrl
    request options, (err, res, body) ->
        writeToFile "list-#{page}.html", body
        cb err, body

startParsing = ->
    console.log 'Cool, logged in.'
    pagesToGet = [1..config.tripPages]

    console.log 'Getting pages', pagesToGet
    async.mapLimit pagesToGet, CONCURRENCY, requestTripList, (err, result) ->
        throw err if err
        console.log "Fetched all pages, got #{result.length} results"
        combined = result.join ' '
        writeToFile 'lists-combined.html', combined
        $ = cheerio.load combined
        trips = $ '.trip-expand__origin'

        tripIds = trips.map (i, trip) -> $(trip).attr('data-target')[6...]
            .toArray()

        async.mapLimit tripIds, CONCURRENCY, downloadTrip, (err, results) ->
            throw err if err
            console.log 'Finished downloading all trips'
            writeToFile 'uberRideStats.json', JSON.stringify results

downloadTrip = (tripId, cb) ->
    tripUrl = "https://riders.uber.com/trips/#{tripId}"
    console.log "Downloading trip #{tripId}"
    request tripUrl, (err, res, body) ->
        throw err if err
        writeToFile "trip-#{tripId}.html", body
        parseStats tripId, body, cb

parseStats = (tripId, html, cb) ->
    stats = {id: tripId, fare: {}}
    $ = cheerio.load html

    imgSrc = $('.img--full.img--flush').attr 'src'
    urlParts = url.parse imgSrc, true
    rawJourney = urlParts.query.path.split('|')[2..]
    stats.journey = _.map rawJourney, (pair) -> pair.split ','

    stats.fare =
        charged: $('.fare-breakdown tr:last-child td:last-child').text()
        total: $('.fare-breakdown tr.separated--top.weight--semibold td:last-child').text()

    $('.fare-breakdown tr').each (i, ele) ->
        $ele = $(ele)
        [col1, col2, col3] = $ele.find 'td'
        [text1, text2, text3] = [$(col1).text(), $(col2).text(), $(col3).text()]

        if text1 and text2
            label = text1.toLowerCase()
            value = text2
        else if text2 and text3
            label = text2.toLowerCase()
            value = text3
        else if text1 and text3
            label = text1.toLowerCase()
            value = text3

        switch label
            when 'base fare' then key = 'base'
            when 'distance' then key = 'distance'
            when 'time' then key = 'time'
            when 'subtotal' then key = 'total'
            when 'uber credit' then key = 'credit'
        key = 'charged' if label.indexOf('charged') > -1

        stats.fare[key or label] = value

    tripAttributes = $('.trip-details__breakdown .soft--top .flexbox__item')
    tripAttributes.each (i, ele) ->
        $ele = $ ele
        label = $ele.find('div').text().toLowerCase()
        value = $ele.find('h5').text()

        switch label
            when 'car'
                key = 'car'
                value = CAR_MAP[value] or value
            when 'kilometers' then key = 'distance'
            when 'trip time' then key = 'duration'

        stats[key] = value

    $rating = $('.rating-complete')
    if $rating
        stats.rating = $rating.find('.star--active').length

    stats.endTime      = $('.trip-address:last-child p').text()
    stats.startTime    = $('.trip-address:first-child p').text()
    stats.endAddress   = $('.trip-address:last-child h6').text()
    stats.startAddress = $('.trip-address:first-child h6').text()

    stats.date = $('.page-lead div').text()
    stats.driverName = $('.trip-details__review .grid__item:first-child td:last-child').text().replace('You rode with ', '')

    writeToFile "stats-#{tripId}.json", JSON.stringify stats
    cb null, stats