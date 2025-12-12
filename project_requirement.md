./mq_client_queue_test.sh IEFQF001 ING.EGRESS.IEO.Q02 QM00000164A_NGS
1. First parameter is source qmgr where script connects in bindings mode no client mode
2. Second parameter is Target queue where message needs to put by amqsput. ofcourse that queue will not be available on source qmgr. but we have to use thats wheat qmgr alis helps
3. Third parameter is Target qmgr name which we supply to the amqsput as target qmgr name. but script has to work with source qmgr only

Note : for amqsput 8208 0 are the open and close options

Logic is : script need to foucs on 3rd parameter and it is available in source qmgr as QREMOTE object with out RNAME. 
Step 1 : find attributes of QM00000164A_NGS like DIS QR(QM00000164A_NGS) RQMNAME XMITQ 
Step 2 : register RQMNAME value as actual target qmgr name and we use this to only display in summary
Step 3 : find the xmitq value and check depth - finally display in summary Transmission queue : name of it, curdepth 
Step 4 : Find the sdr channel based on xmitq,  status, if it is inactive, just do ping test and publish in summary like channel is inactive but ping is good. or if the channel is running just print channel is running or if any other status like retrying. just do ping test and print channel is retrying, ping result )

Finally display summary. other parameters like -s -m as usual to sync with these changes

Ask me if you have any questions
