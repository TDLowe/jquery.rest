'use strict'

#helpers
error = (msg) ->
  throw "ERROR: jquery.rest: #{msg}"

s = (n) -> t = ""; t += "  " while n-- >0; t

encode64 = (s) ->
  error "You need a polyfill for 'btoa' to use basic auth." unless window.btoa
  window.btoa s

stringify = (obj) ->
  error "You need a polyfill for 'JSON' to use stringify." unless window.JSON
  window.JSON.stringify obj

inheritExtend = (a, b) ->
  F = () ->
  F.prototype = a
  $.extend true, new F(), b

validateOpts = (options) ->
  return false unless options and $.isPlainObject options
  $.each options, (name) ->
    error "Unknown option: '#{name}'" if defaultOpts[name] is `undefined`
  null

validateStr = (name, str) ->
  error "'#{name}' must be a string" unless 'string' is $.type str

#defaults
defaultOpts =
  url: ''
  cache: 0
  cachableMethods: ['GET']
  stringifyData: false
  stripTrailingSlash: false
  password: null
  username: null
  verbs:
    'create' : 'POST'
    'read'   : 'GET'
    'update' : 'PUT'
    'delete' : 'DELETE'
  ajax:
    dataType: 'json'

#ajax cache with timeouts
class Cache
  constructor: (@parent) ->
    @c = {}
  valid: (date) ->
    diff = new Date().getTime() - date.getTime()
    return diff <= @parent.opts.cache*1000
  key: (obj) ->
    key = ""
    $.each obj, (k,v) => 
      key += k + "=" + (if $.isPlainObject(v) then "{"+@key(v)+"}" else v) + "|"
    key
  get: (key) ->
    result = @c[key]
    unless result
      return 
    if @valid result.created
      return result.data
    return
  put: (key, data) ->
    @c[key] =
      created: new Date()
      data: data
  clear: (regexp) ->
    if regexp
      $.each @c, (k) =>
        delete @c[k] if k.match regexp
    else
      @c = {}

#represents one verb Create,Read,...
class Verb
  constructor: (@name, @method, options = {}, @parent) ->
    validateStr 'name', @name
    validateStr 'method', @method
    validateOpts options
    error "Cannot add Verb: '#{name}' already exists" if @parent[@name]
    @method = method.toUpperCase()

    #default url to blank
    options.url = '' unless options.url
    @opts = inheritExtend @parent.opts, options
    @root = @parent.root
    @custom = !defaultOpts.verbs[@name]

    #bind call to this instance and save reference
    @call = $.proxy @call, @
    @call.instance = @

  call: ->
    #will execute in the context of the parent resource
    r = @parent.extractUrlData @method, arguments
    r.url += @opts.url or @name if @custom
    @parent.ajax.call @, @method, r.url, r.data

  show: (d) ->
    console.log s(d) + @name + ": " + @method

#resource class - represents one set of crud ops
class Resource

  constructor: (nameOrUrl, options = {}, parent) ->
    validateOpts options
    if parent and parent instanceof Resource
      @name = nameOrUrl
      validateStr 'name', @name
      @constructChild parent, options
    else
      @url = nameOrUrl || ''
      validateStr 'url', @url
      @constructRoot options

  constructRoot: (options) ->
    @opts = inheritExtend defaultOpts, options
    @root = @
    @numParents = 0
    @urlNoId = @url

    @cache = new Cache @
    @parent = null
    @name = @opts.name || 'ROOT'

  constructChild: (@parent, options) ->
    validateStr 'name', @name
    @error "Invalid parent"  unless @parent instanceof Resource
    @error "'#{name}' already exists" if @parent[@name]

    options.url = '' unless options.url
    @opts = inheritExtend @parent.opts, options
    @root = @parent.root
    @numParents = @parent.numParents + 1
    @urlNoId = @parent.url + "#{@opts.url || @name}/"
    @url = @urlNoId + ":ID_#{@numParents}/"

    #add all verbs defined for this resource 
    $.each @opts.verbs, $.proxy @addVerb, @
    @del = @delete if @delete

  error: (msg) ->
    error "Cannot add Resource: " + msg

  add: (name, options) ->
    @[name] = new Resource name, options, @

  addVerb: (name, method, options) ->
    @[name] = new Verb(name, method, options, @).call
  
  show: (d=0)->
    error "Plugin Bug! Recursion Fail" if d > 25
    console.log(s(d)+@name+": " + @url) if @name
    $.each @, (name, fn) ->
      fn.instance.show(d+1) if $.type(fn) is 'function' and fn.instance instanceof Verb and name isnt 'del'
    $.each @, (name,res) =>
      if name isnt "parent" and name isnt "root" and res instanceof Resource
        res.show(d+1)
    null

  toString: ->
    @name

  extractUrlData: (name, args) ->
    ids = []
    data = null
    for arg in args
      t = $.type(arg)
      if t is 'string' or t is 'number'
        ids.push(arg)
      else if $.isPlainObject(arg) and data is null
        data = arg 
      else
        error "Invalid argument: #{arg} (#{t})." + 
              " Must be strings or ints (IDs) followed by one optional plain object (data)."

    numIds = ids.length

    canUrl = name isnt 'create'
    canUrlNoId = name isnt 'update' and name isnt 'delete'
    
    url = null
    url = @url if canUrl and numIds is @numParents
    url = @urlNoId if canUrlNoId and numIds is @numParents - 1
    
    if url is null
      msg = (@numParents - 1) if canUrlNoId
      msg = ((if msg then msg+' or ' else '') + @numParents) if canUrl
      error "Invalid number of ID arguments, required #{msg}, provided #{numIds}"

    for id, i in ids
      url = url.replace new RegExp("\/:ID_#{i+1}\/"), "/#{id}/"

    {url, data}

  ajax: (method, url, data, headers = {})->
    error "method missing"  unless method
    error "url missing"  unless url
    # console.log method, url, data
    if @opts.username and @opts.password
      encoded = encode64 @opts.username + ":" + @opts.password
      headers.Authorization = "Basic #{encoded}"

    if data and @opts.stringifyData
      data = stringify data

    if @opts.stripTrailingSlash
      url = url.replace /\/$/, ""

    ajaxOpts = { url, type:method, headers }
    ajaxOpts.data = data if data
    #add this verb's/resource's defaults
    ajaxOpts = $.extend true, {}, @opts.ajax, ajaxOpts 

    useCache = @opts.cache and $.inArray(method, @opts.cachableMethods) >= 0

    if useCache
      key = @root.cache.key ajaxOpts
      req = @root.cache.get key
      return req if req

    req = $.ajax ajaxOpts

    if useCache
      req.done => @root.cache.put key, req

    return req

# Public API
Resource.defaults = defaultOpts

$.RestClient = Resource
