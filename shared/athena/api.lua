require 'net.http.cache'
local AthenaSource = require 'athena.athena_source'
local AthenaSource2 = require 'athena.athena_docs2'
local store2 = require 'athena.store2'
local store = store2.connect('athena.db')

local Key
local Config

local athena = {}
local token = {}
local api = {}
local Url = { root = 'https://api.athenahealth.com/', repository = 'preview1/', tokenPath = 'oauthpreview/token' }

local function CheckClearCache(DoClear)
   if DoClear then
      store:reset()
   end
end

local function GetAccessTokenViaHTTP(CacheKey, Parameters)
   trace(Parameters, Url)
   local J = net.http.post{url=Url.root..Url.tokenPath, auth=Parameters.auth,
      live=true, parameters= {grant_type = 'client_credentials'} }
   store:put(CacheKey, J)
   store:put(CacheKey..'_time', os.ts.time())
   return json.parse{data=J}
end

local function CheckTokenValid(CacheKey, T)
   local Time = store:get(CacheKey..'_time')
   local CacheData = store:get(CacheKey)
   CacheData = json.parse{data = CacheData}
   trace(os.ts.difftime(os.ts.time(), Time))
   if os.ts.difftime(os.ts.time(), Time) > CacheData.expires_in then
      CheckClearCache(true)
      GetAccessTokenViaHTTP(CacheKey, T)
   end
end

local function GetAccessTokenCached(CacheKey, T)
   local S = store:get(CacheKey)
   if(S) then
      S = json.parse{data=S}
      if(S.error) then
         return nil
      else 
         CheckTokenValid(CacheKey, T)
         return S
      end
   end
   return nil
end

----------------------------------------------------------------------------------
-- This function checks if there has been a call recently made to this get function
-- in order to save time.
-- @params Data: the Api being called
-- @params P: Parameters necessary for the api call
   -- 2 sub tables : web, body
   -- web : parameter substitutes for api path variables
   -- body : paramters added to end of path
-- @calltype : the type of AJAX call being made (get, post, put, or delete)
----------------------------------------------------------------------------------
local function checkCache(Api, P, calltype) 
   if iguana.isTest() then
      -- no caching when running in production
      return api.call(Api, P, calltype)
   end
   local Time = os.ts.time()
   local Key = json.serialize{data=P, compact=true}:gsub('["{}:,%]\[]', "")
   if store:get(Key..'_time') and calltype == 'read'
      and Time - store:get(Key .. '_time') < 400000 then
      return json.parse{data=store:get(Key)}
   end
   local R = api.call(Api, P, calltype)
   if iguana.isTest() and calltype=='read' then
      store:put(Key, json.serialize{data=R})
      store:put(Key.."_time", os.ts.time())
   end
   return R
end

local function ApiCall(UserParams, Data, typeof)
   local ExpectedParams = Data.parameters
   trace(UserParams, ExpectedParams, typeof)
   local Params = {path = {}, web = {}}
   for K, V in pairs(ExpectedParams) do
      if(K ~= 'Authorization' or K ~= 'Content-Type') then
         if V.location ~= 'pathReplace' then 
            Params.web[K] = UserParams[K]
         elseif V.location == 'pathReplace' then
            local Key = string.sub(K, 2, string.len(K))
            Params.path[K] = UserParams[Key]
         end
      end
   end
   return checkCache(Data.path, Params, typeof)
end

local function handleErrors(Response, Err, Header, Extras)
   iguana.logInfo(Response)
   if Err ~= 200 then -- For all responses other thsn 200 OK
       if Err == 401 then --Failed Authorization
         --Problem to look into later : config and Key are now not local
         trace(token)
         local tempToken = GetAccessTokenViaHTTP('access_token', {auth={username=Config.load{config='athena_key', key=Key}, 
                  password=Config.load{config='athena_secret', key=Key}}}).access_token
         trace(tempToken)
         Extras.P.header.Authorization = "Bearer "..tempToken
         Response, E, Header = api[Extras.typeof](Extras.api, Extras.P) --Retry the Api call
         if E ~= 200 then
            error('Failed to Authorize', 6)
         else
            return json.parse{data=Response}
         end
      end
      if Err == 400 or Err == 403 then     
         local ResponseError = ''
         local Response = json.parse{data=Response}
         ResponseError = ResponseError..Response.error..'\n'
         for K, V in pairs(Response) do
            trace(K)
            if(K ~= 'error') then
               local BonusData = ''
               for K2,V2 in pairs(V) do
                  BonusData = BonusData..V2..' '
               end
               ResponseError = ResponseError..' '..BonusData
            end
            trace(ResponseError)
         end
         error('API response error: ' .. Err .. ' ( '..ResponseError..' ) returned for query call.', 6)  
         return
      end
      if Err == 596 then
         error('Service not found', 6)
      end
   else -- return data from successful 200 OK response
      if Response ~= '' then
         return json.parse{data=Response}
      end       
   end
end

local function MakeParamsArray(Params)
   local i = 0
   local Result = {}
   for Key, V in pairs(Params.parameters) do 
      if(string.sub(Key, 0, 1) == ':') then
         Key = string.sub(Key, 2, string.len(Key))
      end
      if Key ~= 'Authorization' and K~= 'Content-Type' then
         trace(Key)
         Result[i] = {}
         Result[i][Key] = {}
         Result[i][Key].Opt = not V.required
         Result[i][Key].Desc = V.description
         if(V.type) then
            Result[i][Key].Desc = Result[i][Key].Desc..' ('..V.type..')'
         end
         i = i + 1
      end   
   end
   return Result
end   

local function translateToCrud(def)
   if     def == 'GET'  then  return 'read'
   elseif def == 'POST' then  return 'add'
   elseif def == 'PUT'  then  return 'update'
   end
   return 'delete'
end

local function MakeHelp(Table, func)
   trace(Table)
   local HelpInfo = {}
   HelpInfo.Desc = Table.description
   HelpInfo.ParameterTable = true
   HelpInfo.Parameters = MakeParamsArray(Table)
   HelpInfo.Title = "Api: "..Table.path
   help.set{input_function=func, help_data=HelpInfo}
end

local function makeObj(Data, a, Index)
   local Path = Data.path
   local typeof = translateToCrud(Data.httpMethod)
   local Table = string.split(Path, '/')
   local subStr = string.sub(Table[Index], 0, 1)
   if(subStr == ':') then
      Table[Index] = string.sub(Table[Index], 2, string.len(Table[Index]))
   end
   if Index == #Table then
      trace(a[Table[Index]])
      if not a[Table[Index]] then 
         a[Table[Index]] = {[typeof] = function(P) return ApiCall(P, Data ,typeof) end}
         MakeHelp(Data, a[Table[Index]][typeof])
      else
         a[Table[Index]][typeof] = function(P) return  ApiCall(P, Data ,typeof) end
         MakeHelp(Data, a[Table[Index]][typeof])
      end
   elseif not a[Table[Index]] then
      a[Table[Index]] = {}
      makeObj(Data, a[Table[Index]], Index + 1)
   elseif a[Table[Index]] then
      makeObj(Data, a[Table[Index]], Index + 1)
   end   
end

local function init()
   local ApiData = json.parse{data=AthenaSource}
   local ApiData = json.parse{data=AthenaSource2}
   trace(ApiData)
   local a  = {}
   for K,V in pairs(ApiData.resources) do
      local Subsection = string.split(K, '/')
      Subsection = string.split(Subsection[1], ' ')
      Subsection = string.lower(Subsection[1])
      if not a[Subsection] then a[Subsection] = {} end
      for Method in pairs(V.methods) do
         makeObj(ApiData.resources[K].methods[Method], a[Subsection], 4)
      end 
   end
   trace(a)
   return a
end

----------------------------------------------------------------------------------
-- The following 4 functions are for the 4 supported AJAX calls for Athena Health
-- @params api: The api call being made
-- @params params: Parameters necessary for the api call
   -- 3 sub tables : web, body, header
   -- web : parameter substitutes for api path variables
   -- body : paramters added to end of path
   -- header : header parameters i.e. Authorization and Connection
----------------------------------------------------------------------------------
function api.read(api, params)
   trace(params, token)
   local Result, E, Header = net.http.get{url=Url.root..api, headers=params.header, parameters=params.web, live=true, cache_time=60}
   trace(Result, E, Header)
   return Result, E, Header
end

function api.add(api, params)
   trace(params.header, params.web)
   local Result, E, Header = net.http.post{url=Url.root..api, headers=params.header, parameters=params.web, live=true, cache_time=60}
   return Result, E, Header
end

local function urlEncodeParams(Params)
   local Result = ''
   for K, V in pairs(Params) do
      Result = Result ..K..'='..filter.uri.enc(V)..'&'
   end
   return Result:sub(1, #Result-1)
end

function api.update(api, params)
   local data = urlEncodeParams(params.web)
   if(data == '') then --It wont let me do the request with just an empty string
      data = 'blank=yes'
   end   
   local Result, E, Header = net.http.put{url=Url.root..api, headers=params.header, data=data, live=true, cache_time=60}
   return Result, E, Header
end

function api.delete(api, params)
   trace(params)
   local QueryParams = '?'
   for K, V in pairs(params.web) do
      QueryParams = QueryParams..K..'='..V..'&'
   end
   QueryParams = string.sub(QueryParams, 0, string.len(QueryParams) - 1)   
   local Result, E, Header = net.http.delete{url = Url.root..api..QueryParams, headers=params.header, live=true, cache_time=60}
   return Result, E, Header
end
----------------------------------------------------------------------------------
-- Substitutes the appropriate path variables into the api
-- @params api: The api call being made
-- @params params: a table of web variables ot their values to be substituted into
-- the url
----------------------------------------------------------------------------------
local function createUrl(params, api)
   if (api:sub(0, 3) == '/v1') then -- handles new fhir nonsense
      api = 'preview1'..api:sub(4, #api) --idk if this should be preview1 or w.e they use.
   end
   trace(api)
   for K, V in pairs(params) do
      trace(K, V)
      local start, stop = api:find(K, nil)
      trace(start, stop)
      if(start ~= nil) then
         local beginning = api:sub(1, start - 1)
         local ending = api:sub(stop + 1, api:len())
         trace(beginning, ending)
         api = beginning..V..ending
      end
   end
   trace(api)
   return api
end
----------------------------------------------------------------------------------
-- The main function called when you want to make an AJAX call
-- @params api: The api call being made
-- @params params: Parameters necessary for the api call
   -- 3 sub tables : web, body, header
   -- web : parameter substitutes for api path variables
   -- body : paramters added to end of path
   -- header : header parameters i.e. Authorization and Connection
-- @calltype : the type of AJAX call being made (get, post, put, or delete)
----------------------------------------------------------------------------------
function api.call(Api, params, calltype) 
   trace(token)
   params.header = { Authorization = "Bearer "..token.access_token, Connection = 'keep-alive'}
   Api = createUrl(params.path, Api)
   local Result, Header, E = {}, {}, 0
   Result, E, Header = api[calltype](Api, params)
   return handleErrors(Result, E, Header, {api = Api, P = params, typeof = calltype})
end

----------------------------------------------------------------------------------
-- Used to connected to Athena Help based on client key and client secret
-- Tries to find a cached token, if not will make an ajax call to get a new one
-- and store it, as well as store the time it was accessed
-- @params T:  Contains client key and secret and information necessary for
-- connection
----------------------------------------------------------------------------------
function athena.connect(Credentials)
   Config = Credentials.config
   Key = Credentials.key
   local T = {auth = {username = Credentials.username, password = Credentials.password},
         grant_type = 'client_credentials', 
         clear_cache = Credentials.cache,
         key = 'access_data'}
   CheckClearCache(not T.clear_cache)
   token = GetAccessTokenCached(T.key, T) or GetAccessTokenViaHTTP(T.key, T)
   if token.error then
      error(token.error, 2)
   end
   return init()
end
--- setting help for athena.connect
local HelpInfo = {Title = 'athena.connect', Desc = 'Connect to Athena server', ParameterTable = true, Parameters = {}}
HelpInfo.Parameters[1] = {['username'] = {['Desc'] = 'client key for the app', ['Opt'] = false }}
HelpInfo.Parameters[2] = {['password'] = {['Desc'] = 'client secret for the app', ['Opt'] = false }}
HelpInfo.Parameters[3] = {['cache'] = {['Desc'] = 'keep a cache of app token', ['Opt'] = false }}
HelpInfo.Parameters[4] = {['config'] = {['Desc'] = 'configuration object', ['Opt'] = false }}
HelpInfo.Parameters[5] = {['key'] = {['Desc'] = 'key to configuration file', ['Opt'] = false }}

trace(HelpInfo)
help.set{input_function=athena.connect, help_data=HelpInfo}

return athena