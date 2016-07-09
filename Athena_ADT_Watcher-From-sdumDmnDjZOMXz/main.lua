-- This demonstrates a wrapper for the Athena RESTful web API
-- We are looking at Athena for new patients being added to the Athena application

-- http://help.interfaceware.com/v6/athena-adt-watcher

local config = require 'encrypt.password'
local Key = 'sdfasdfakdsakjfweiuhwifsdfsfsdeuhwiuhc'
local AthenaConnect = require 'athena.api'
local PracticeId = 195900 -- Replace with your Practice Id

-- Follow these steps to store Athena server credentials securely in 2 configuration files
-- This method is much more secure than saving database credentials in the Lua script
-- NOTE: (step 4) Be careful not to save a milestone containing password information
-- See http://help.interfaceware.com/v6/encrypt-password-in-file
--  1) Enter them into these lines
--  2) Uncomment the lines
--  3) Recomment the lines
--  4) Remove the password and STMP servername from the file *BEFORE* you same a milestone

--config.save{key=Key,config="athena_key",    password="EDIT ME - username to athena server (application key)"}
--config.save{key=Key,config="athena_secret", password="EDIT ME - password to athena server (application secret)"}

function main() 
	-- load user name and password from encrypted storage
   local Username = config.load{config='athena_key', key=Key}
   local Password = config.load{config='athena_secret', key=Key}
   
   -- Create a connection - returns a connection table
   local A = AthenaConnect{username=Username, password=Password, key=Key, config=config, cache=true}
      
   local Patients
   -- If we had a real instance of Athena Health then we would register the real practice ID
   -- A.patients.patients.changed.subscription.add{practiceid=PracticeId}

   -- Then watch for any changed patient details using patients.changed
   Patients = A.patients.patients.changed.read{practiceid=195900,leaveunprocessed=iguana.isTest()}

   -- Here are some other API examples to play around with, they may not work in all cases
   -- for more information on the Athena API see https://developer.athenahealth.com/docs

   -- a simple query for male patients who last name is "Smith"
   --Patients = A.patients.patients.read{practiceid=PracticeId,sex='M', lastname='Smith'}
   
   -- get department information for all departments for a Practice Id
   --A.administrative.departments.read{practiceid=PracticeId}
   
   -- test for access to a practiceId using "ping.read" - return true or false
   --hasAccess = A.administrative.ping.read{practiceid=PracticeId}
   --hasAccess = A.administrative.ping.read{practiceid=195901} -- try and see what happens
   
   -- get chart configuration information
   --local Y = A.chart.chart.configuration.medicalhistory.read{practiceid=PracticeId}

   -- In this case we push the changed patients into the queue and process them downstream.
   for i=1, #Patients.patients do  
      queue.push{data=json.serialize{data=Patients.patients[i]}}
   end
end
