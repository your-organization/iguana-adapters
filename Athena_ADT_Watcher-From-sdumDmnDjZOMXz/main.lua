-- This demonstrates a wrapper for the Athena RESTful web API
-- We are looking at Athena for new patients being added to the Athena application
-- See http://help.interfaceware.com/forums/topic/athena-health-web-adapter

local config = require 'encrypt.password'
local Key = 'sdfasdfakdsakjfweiuhwifsdfsfsdeuhwiuhc'
local athena = require 'athena.api'
local PracticeId = 195900 --Replace with your Practice Id

-- Follow these steps to store Athena server credentials securely in 2 configuration files
-- This method is much more secure than saving database credentials in the Lua script
-- NOTE: (step 4) Be careful not to save a milestone containing password information
-- See http://help.interfaceware.com/v6/encrypt-password-in-file
--  1) Enter them into these lines
--  2) Uncomment the lines.
--  3) Recomment the lines
--  4) Remove the password and STMP servername from the file *BEFORE* you same a milestone

--config.save{key=Key,config="athena_key",      password="EDIT ME - username to athena server (application key)"}
--config.save{key=Key,config="athena_password", password="EDIT ME - password to athena server (application secret)"}

function main() 
   local Username = config.load{config='athena_key', key=Key}
   local Password = config.load{config='athena_secret', key=Key}
   local A = athena.connect{username=Username, password=Password, cache=true}
   
   local Patients
   -- If we had a real instance of Athena Health then we would register this practice ID
   -- A.patients.patients.changed.subscription.add{practiceid=PracticeId}
   -- Then the patients.changed 
   Patients = A.patients.patients.changed.read{practiceid=195900,leaveunprocessed=iguana.isTest()}

   -- For a real athena health instance you'd like want to get rid of this line since we
   -- are querying male patients who last name is "Smith"
   --Patients = A.patients.patients.read{practiceid=PracticeId,sex='M', lastn--ame='Smith'}
   --Patients = A.administrative.ping.read{practiceid=289301}
   local Y = A.chart.chart.configuration.medicalhistory.read{practiceid=PracticeId}
   -- In this case we push the patients into the queue and we'll process them downstream.
   for i=1, #Patients.patients do  
      queue.push{data=json.serialize{data=Patients.patients[i]}}
   end
end
