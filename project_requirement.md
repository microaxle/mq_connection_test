We have project requirement for IBM MQ
I need to send the test message when user give qmgr namd and queue namage to the script. but before that i need to auto discover all related MQ Objects and print the stats.
For example user give qmgr as APEX.C1.MEM1 and queue name as APEX.TO.OMNI.WIRE.REQ
Then script auto discover dependend objects like Xmitq and it state, sdr channel and its state then target qmgr state, then target rcvr channel 
Once we are good with all these IBM MQ objects good then proceed for test message.
Please give me simple shell script which runs inside the server where qmgr is there.