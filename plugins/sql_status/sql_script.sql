USE Master;
SET ANSI_NULLS ON
SET QUOTED_IDENTIFIER ON
--=============================================================================
-- Desc: Returns various pieces of information about the current instance to
-- aid in troubleshooting.
--
-- Auth: Mark Wilkinson
-- Date: 2015.04.20 09:39:54
--=============================================================================

SET NOCOUNT ON

--== Variables and Tables =====================================================
DECLARE
    @baseData VARCHAR(MAX),
    @deltaStr CHAR(8),
    @timeStampNow BIGINT,
    @timeStampCPUFrom BIGINT,
    @cpuCount INT,
    @serverMemoryGB NUMERIC(6,2),
    @maxMemoryGB NUMERIC(6,2),
    @logHistoryMin INT = 15,
    @logStart DATETIME,
    @logDataXML XML,
    --@cpuUsage NUMERIC(5,2),
    @maxDop INT,
    @loadFactor INT,
    @loadFactorDetail XML,
    @freeTempMB INT,
    @freeTempPct NUMERIC(6,2),
    @tempDBVersionStore INT,
    @sessionTotal INT,
    @sessionActive INT,
    @blockedSessions INT,
    @maxDuration INT,
    @workers INT,
    @maxWorkers INT,
    @dbCount INT,
    @dbDetail XML,
    @pendingMemoryGrants INT,
    @serverTime DATETIME = GETDATE(),
    @serverStartTime DATETIME,
    @readLatency NUMERIC(6,2),
    @writeLatency NUMERIC(6,2),
    @mountPointData NVARCHAR(MAX),
    @PLE INT,
    @AGHealth NVARCHAR(MAX),
    @memoryDetail NVARCHAR(MAX),
    @AgentStatus NVARCHAR(MAX),
    @waitData NVARCHAR(MAX);

SET @logStart = DATEADD(MINUTE,-(@logHistoryMin),GETDATE())

--=============================================================================
--== CPU Count, max workers
SELECT
    @cpuCount = cpu_count,
    @maxWorkers = max_workers_count,
    @serverStartTime = sqlserver_start_time,
    @serverMemoryGB = (physical_memory_kb/1024.0)/1024.0
FROM
    sys.dm_os_sys_info WITH (NOLOCK);

--== Get max memory
SELECT @maxMemoryGB = ( CAST(value_in_use AS BIGINT) / 1024.0 ) from sys.configurations where name = 'max server memory (MB)'

--== Memory Detail
SET @memoryDetail = (
SELECT  TOP(5)
        REPLACE(REPLACE(
        '{type}: {size}
'
        ,'{type}',REPLICATE(' ',30 - LEN(type)) + type)
        ,'{size}',CAST((SUM(pages_kb) / 1024.0 /1024.0) AS NUMERIC(12,2)))
FROM    sys.dm_os_memory_clerks
GROUP BY type
ORDER BY SUM(pages_kb) DESC
FOR XML PATH(''), TYPE
).value('.','nvarchar(max)')

--== Get MAXDOP
SELECT
    @maxDop = CAST(value_in_use AS INT)
FROM
    sys.configurations WITH (NOLOCK)
WHERE
    name = 'max degree of parallelism';

--== Load Factor
SELECT
    @loadFactor = AVG(load_factor)
FROM
    sys.dm_os_schedulers WITH (NOLOCK)
WHERE
    scheduler_id < @cpuCount;

--== Get tempDB free
SELECT
    @freeTempMB = CAST((SUM(unallocated_extent_page_count)*1.0/128) AS INT),
    @freeTempPct = CAST( ((SUM(unallocated_extent_page_count)*1.0/128) / (SUM(total_page_count)*1.0/128)) AS NUMERIC(6,2)) * 100.00,
    @tempDBVersionStore = CAST((SUM(version_store_reserved_page_count)*1.0/128) AS INT)
FROM
    tempdb.sys.dm_db_file_space_usage WITH (NOLOCK);

--== Get Pending memory Grants
SELECT  @pendingMemoryGrants = COUNT(*)
FROM    sys.dm_exec_query_memory_grants WITH (NOLOCK)
WHERE   granted_memory_kb IS NULL;

--== Get worker threads
SELECT
    @workers = COUNT(*)
FROM
    sys.dm_os_workers WITH (NOLOCK);

--== Get session data
SELECT
    @sessionTotal = COUNT(*),
    @sessionActive = SUM(CASE WHEN er.session_id IS NULL THEN 0 ELSE 1 END),
    @maxDuration = MAX(DATEDIFF(second,er.start_time,GETDATE())),
    @blockedSessions = SUM(CASE WHEN NULLIF(er.blocking_session_id,0) IS NULL THEN 0 ELSE 1 END)
FROM
    sys.dm_exec_sessions AS es WITH (NOLOCK)
    LEFT OUTER JOIN sys.dm_exec_requests AS er WITH (NOLOCK)
        ON es.session_id = er.session_id
WHERE
    es.is_user_process = 1
OPTION(RECOMPILE, MAXDOP 1);

--== IO Summary Stats
WITH IOCTE AS (
    SELECT
        db_name(vfs.[database_id]) AS databaseName,
        vfs.database_id,
        [readLatency] = ISNULL(AVG(vfs.[io_stall_read_ms] / NULLIF(vfs.[num_of_reads],0)),0),
        [writeLatency] = ISNULL(AVG(vfs.[io_stall_write_ms] / NULLIF(vfs.[num_of_writes],0)),0)
    FROM
        sys.dm_io_virtual_file_stats (NULL, NULL) AS vfs
        INNER JOIN sys.master_files AS mf WITH (NOLOCK)
            ON vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id
    GROUP BY
        vfs.[database_id]
)
SELECT
    @readLatency = AVG(readLatency),
    @writeLatency = AVG(writeLatency)
FROM
    IOCTE

--== Mount Point capacity data
SELECT @mountPointData = (
    SELECT DISTINCT
            REPLACE(REPLACE(REPLACE(REPLACE(
            '    {{mp}}: {{ts}}GB, {{as}}GB, {{fp}}%
'
            ,'{{mp}}',vs.volume_mount_point)
            ,'{{ts}}',CONVERT(DECIMAL(18, 2), vs.total_bytes / 1073741824.0))
            ,'{{as}}',CONVERT(DECIMAL(18, 2), vs.available_bytes / 1073741824.0))
            ,'{{fp}}',CAST(CAST(vs.available_bytes AS FLOAT) / CAST(vs.total_bytes AS FLOAT) AS DECIMAL(18,2)) * 100)
    FROM    sys.master_files AS f WITH ( NOLOCK )
            CROSS APPLY sys.dm_os_volume_stats(f.database_id, f.[file_id]) AS vs
    WHERE   f.database_id NOT IN ( SELECT database_id FROM sys.databases WITH( NOLOCK ) WHERE state = 2 )
    FOR XML PATH(''), TYPE
).value('.','nvarchar(max)')

--== AG Health
SELECT @AGHealth = (
SELECT 
        REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
        '    {{ag}} - {{server}} ({{role}}): {{state}} - {{health}}
'
        ,'{{server}}',ar.replica_server_name)
        ,'{{role}}',SUBSTRING(rs.role_desc,1,1))
        ,'{{state}}',rs.connected_state_desc)
        ,'{{health}}',rs.synchronization_health_desc)
        ,'{{ag}}',ag.name)
FROM    sys.dm_hadr_availability_replica_states AS rs WITH (NOLOCK)
        INNER JOIN sys.availability_replicas AS ar WITH (NOLOCK)
            ON rs.replica_id = ar.replica_id
        INNER JOIN sys.availability_groups AS ag WITH (NOLOCK)
            ON rs.group_id = ag.group_id
ORDER BY ag.name,role
FOR XML PATH(''), TYPE
).value('.','nvarchar(max)')

--== PLE
SELECT  @PLE = cntr_value
FROM    sys.dm_os_performance_counters
WHERE   counter_name = 'Page life expectancy'
        AND object_name = 'SQLServer:Buffer Manager';

--== CPU Usage
DECLARE @avg15 NUMERIC(4,1),
        @avg60 NUMERIC(4,1),
        @avg240 NUMERIC(4,1)

--== Get timestamp data for CPU Graphing.
SELECT
    @timeStampNow = (cpu_ticks / ( cpu_ticks / ms_ticks ))
FROM
    sys.dm_os_sys_info;

-- Taken from Glenn Berry's Diagnostic Queries
WITH CPUCTE AS (
    SELECT TOP(240)
        ROW_NUMBER() OVER (ORDER BY y.record_id DESC) AS record_id,
        DATEADD(ms, -1 * (@timeStampNow - [timestamp]), GETDATE()) AS [timestamp],
        SQLProcessUtilization * 1.0 AS cpu_usage
    FROM
        (
            SELECT
                record.value('(./Record/@id)[1]', 'int') AS record_id,
                record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS [SQLProcessUtilization],
                [timestamp]
            FROM
                (
                    SELECT
                        [timestamp],
                        CONVERT(xml, record) AS [record]
                    FROM
                        sys.dm_os_ring_buffers WITH (NOLOCK)
                    WHERE
                        ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
                        AND record LIKE N'%<SystemHealth>%'
                ) AS x
        ) AS y
)
SELECT  @avg15 = AVG( CASE WHEN record_id <= 15 THEN cpu_usage ELSE NULL END ),
        @avg60 = AVG( CASE WHEN record_id <= 60 THEN cpu_usage ELSE NULL END ),
        @avg240 = AVG( CASE WHEN record_id <= 240 THEN cpu_usage ELSE NULL END )
FROM    CPUCTE;

--== Agent Status
SELECT @AgentStatus = status_desc FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server Agent%'

--== Wait Data (32)
SELECT @WaitData = (
SELECT TOP(5)
    REPLACE(REPLACE(REPLACE(
    '  {cat} - Max: {dur}ms, Tasks: {count}
'
    ,'{cat}',COALESCE(wc.wait_category,ws.wait_type))
    ,'{dur}',MAX(ws.wait_duration_ms))
    ,'{count}', COUNT(*))
FROM
    sys.dm_os_waiting_tasks AS ws WITH (NOLOCK)
    LEFT OUTER JOIN ( VALUES
    ('ASYNC_IO_COMPLETION','Other Disk IO'),
    ('ASYNC_NETWORK_IO','Network IO'),
    ('BACKUPIO','Other Disk IO'),
    ('BROKER_CONNECTION_RECEIVE_TASK','Service Broker'),
    ('BROKER_DISPATCHER','Service Broker'),
    ('BROKER_ENDPOINT_STATE_MUTEX','Service Broker'),
    ('BROKER_EVENTHANDLER','Service Broker'),
    ('BROKER_FORWARDER','Service Broker'),
    ('BROKER_INIT','Service Broker'),
    ('BROKER_MASTERSTART','Service Broker'),
    ('BROKER_RECEIVE_WAITFOR','User Wait'),
    ('BROKER_REGISTERALLENDPOINTS','Service Broker'),
    ('BROKER_SERVICE','Service Broker'),
    ('BROKER_SHUTDOWN','Service Broker'),
    ('BROKER_START','Service Broker'),
    ('BROKER_TASK_SHUTDOWN','Service Broker'),
    ('BROKER_TASK_STOP','Service Broker'),
    ('BROKER_TASK_SUBMIT','Service Broker'),
    ('BROKER_TO_FLUSH','Service Broker'),
    ('BROKER_TRANSMISSION_OBJECT','Service Broker'),
    ('BROKER_TRANSMISSION_TABLE','Service Broker'),
    ('BROKER_TRANSMISSION_WORK','Service Broker'),
    ('BROKER_TRANSMITTER','Service Broker'),
    ('CHECKPOINT_QUEUE','Idle'),
    ('CHKPT','Tran Log IO'),
    ('CLR_AUTO_EVENT','SQL CLR'),
    ('CLR_CRST','SQL CLR'),
    ('CLR_JOIN','SQL CLR'),
    ('CLR_MANUAL_EVENT','SQL CLR'),
    ('CLR_MEMORY_SPY','SQL CLR'),
    ('CLR_MONITOR','SQL CLR'),
    ('CLR_RWLOCK_READER','SQL CLR'),
    ('CLR_RWLOCK_WRITER','SQL CLR'),
    ('CLR_SEMAPHORE','SQL CLR'),
    ('CLR_TASK_START','SQL CLR'),
    ('CLRHOST_STATE_ACCESS','SQL CLR'),
    ('CMEMPARTITIONED','Memory'),
    ('CMEMTHREAD','Memory'),
    ('CXPACKET','Parallelism'),
    ('DBMIRROR_DBM_EVENT','Mirroring'),
    ('DBMIRROR_DBM_MUTEX','Mirroring'),
    ('DBMIRROR_EVENTS_QUEUE','Mirroring'),
    ('DBMIRROR_SEND','Mirroring'),
    ('DBMIRROR_WORKER_QUEUE','Mirroring'),
    ('DBMIRRORING_CMD','Mirroring'),
    ('DTC','Transaction'),
    ('DTC_ABORT_REQUEST','Transaction'),
    ('DTC_RESOLVE','Transaction'),
    ('DTC_STATE','Transaction'),
    ('DTC_TMDOWN_REQUEST','Transaction'),
    ('DTC_WAITFOR_OUTCOME','Transaction'),
    ('DTCNEW_ENLIST','Transaction'),
    ('DTCNEW_PREPARE','Transaction'),
    ('DTCNEW_RECOVERY','Transaction'),
    ('DTCNEW_TM','Transaction'),
    ('DTCNEW_TRANSACTION_ENLISTMENT','Transaction'),
    ('DTCPNTSYNC','Transaction'),
    ('EE_PMOLOCK','Memory'),
    ('EXCHANGE','Parallelism'),
    ('EXTERNAL_SCRIPT_NETWORK_IOF','Network IO'),
    ('FCB_REPLICA_READ','Replication'),
    ('FCB_REPLICA_WRITE','Replication'),
    ('FT_COMPROWSET_RWLOCK','Full Text Search'),
    ('FT_IFTS_RWLOCK','Full Text Search'),
    ('FT_IFTS_SCHEDULER_IDLE_WAIT','Idle'),
    ('FT_IFTSHC_MUTEX','Full Text Search'),
    ('FT_IFTSISM_MUTEX','Full Text Search'),
    ('FT_MASTER_MERGE','Full Text Search'),
    ('FT_MASTER_MERGE_COORDINATOR','Full Text Search'),
    ('FT_METADATA_MUTEX','Full Text Search'),
    ('FT_PROPERTYLIST_CACHE','Full Text Search'),
    ('FT_RESTART_CRAWL','Full Text Search'),
    ('FULLTEXT GATHERER','Full Text Search'),
    ('HADR_AG_MUTEX','Replication'),
    ('HADR_AR_CRITICAL_SECTION_ENTRY','Replication'),
    ('HADR_AR_MANAGER_MUTEX','Replication'),
    ('HADR_AR_UNLOAD_COMPLETED','Replication'),
    ('HADR_ARCONTROLLER_NOTIFICATIONS_SUBSCRIBER_LIST','Replication'),
    ('HADR_BACKUP_BULK_LOCK','Replication'),
    ('HADR_BACKUP_QUEUE','Replication'),
    ('HADR_CLUSAPI_CALL','Replication'),
    ('HADR_COMPRESSED_CACHE_SYNC','Replication'),
    ('HADR_CONNECTIVITY_INFO','Replication'),
    ('HADR_DATABASE_FLOW_CONTROL','Replication'),
    ('HADR_DATABASE_VERSIONING_STATE','Replication'),
    ('HADR_DATABASE_WAIT_FOR_RECOVERY','Replication'),
    ('HADR_DATABASE_WAIT_FOR_RESTART','Replication'),
    ('HADR_DATABASE_WAIT_FOR_TRANSITION_TO_VERSIONING','Replication'),
    ('HADR_DB_COMMAND','Replication'),
    ('HADR_DB_OP_COMPLETION_SYNC','Replication'),
    ('HADR_DB_OP_START_SYNC','Replication'),
    ('HADR_DBR_SUBSCRIBER','Replication'),
    ('HADR_DBR_SUBSCRIBER_FILTER_LIST','Replication'),
    ('HADR_DBSEEDING','Replication'),
    ('HADR_DBSEEDING_LIST','Replication'),
    ('HADR_DBSTATECHANGE_SYNC','Replication'),
    ('HADR_FABRIC_CALLBACK','Replication'),
    ('HADR_FILESTREAM_BLOCK_FLUSH','Replication'),
    ('HADR_FILESTREAM_FILE_CLOSE','Replication'),
    ('HADR_FILESTREAM_FILE_REQUEST','Replication'),
    ('HADR_FILESTREAM_IOMGR','Replication'),
    ('HADR_FILESTREAM_IOMGR_IOCOMPLETION','Replication'),
    ('HADR_FILESTREAM_MANAGER','Replication'),
    ('HADR_FILESTREAM_PREPROC','Replication'),
    ('HADR_GROUP_COMMIT','Replication'),
    ('HADR_LOGCAPTURE_SYNC','Replication'),
    ('HADR_LOGCAPTURE_WAIT','Replication'),
    ('HADR_LOGPROGRESS_SYNC','Replication'),
    ('HADR_NOTIFICATION_DEQUEUE','Replication'),
    ('HADR_NOTIFICATION_WORKER_EXCLUSIVE_ACCESS','Replication'),
    ('HADR_NOTIFICATION_WORKER_STARTUP_SYNC','Replication'),
    ('HADR_NOTIFICATION_WORKER_TERMINATION_SYNC','Replication'),
    ('HADR_PARTNER_SYNC','Replication'),
    ('HADR_READ_ALL_NETWORKS','Replication'),
    ('HADR_RECOVERY_WAIT_FOR_CONNECTION','Replication'),
    ('HADR_RECOVERY_WAIT_FOR_UNDO','Replication'),
    ('HADR_REPLICAINFO_SYNC','Replication'),
    ('HADR_SEEDING_CANCELLATION','Replication'),
    ('HADR_SEEDING_FILE_LIST','Replication'),
    ('HADR_SEEDING_LIMIT_BACKUPS','Replication'),
    ('HADR_SEEDING_SYNC_COMPLETION','Replication'),
    ('HADR_SEEDING_TIMEOUT_TASK','Replication'),
    ('HADR_SEEDING_WAIT_FOR_COMPLETION','Replication'),
    ('HADR_SYNC_COMMIT','Replication'),
    ('HADR_SYNCHRONIZING_THROTTLE','Replication'),
    ('HADR_TDS_LISTENER_SYNC','Replication'),
    ('HADR_TDS_LISTENER_SYNC_PROCESSING','Replication'),
    ('HADR_THROTTLE_LOG_RATE_GOVERNOR','Log Rate Governor'),
    ('HADR_TIMER_TASK','Replication'),
    ('HADR_TRANSPORT_DBRLIST','Replication'),
    ('HADR_TRANSPORT_FLOW_CONTROL','Replication'),
    ('HADR_TRANSPORT_SESSION','Replication'),
    ('HADR_WORK_POOL','Replication'),
    ('HADR_WORK_QUEUE','Replication'),
    ('HADR_XRF_STACK_ACCESS','Replication'),
    ('INSTANCE_LOG_RATE_GOVERNOR','Log Rate Governor'),
    ('IO_COMPLETION','Other Disk IO'),
    ('IO_QUEUE_LIMIT','Other Disk IO'),
    ('IO_RETRY','Other Disk IO'),
    ('LATCH_DT','Latch'),
    ('LATCH_EX','Latch'),
    ('LATCH_KP','Latch'),
    ('LATCH_NL','Latch'),
    ('LATCH_SH','Latch'),
    ('LATCH_UP','Latch'),
    ('LAZYWRITER_SLEEP','Idle'),
    ('LCK_M_BU','Lock'),
    ('LCK_M_BU_ABORT_BLOCKERS','Lock'),
    ('LCK_M_BU_LOW_PRIORITY','Lock'),
    ('LCK_M_IS','Lock'),
    ('LCK_M_IS_ABORT_BLOCKERS','Lock'),
    ('LCK_M_IS_LOW_PRIORITY','Lock'),
    ('LCK_M_IU','Lock'),
    ('LCK_M_IU_ABORT_BLOCKERS','Lock'),
    ('LCK_M_IU_LOW_PRIORITY','Lock'),
    ('LCK_M_IX','Lock'),
    ('LCK_M_IX_ABORT_BLOCKERS','Lock'),
    ('LCK_M_IX_LOW_PRIORITY','Lock'),
    ('LCK_M_RIn_NL','Lock'),
    ('LCK_M_RIn_NL_ABORT_BLOCKERS','Lock'),
    ('LCK_M_RIn_NL_LOW_PRIORITY','Lock'),
    ('LCK_M_RIn_S','Lock'),
    ('LCK_M_RIn_S_ABORT_BLOCKERS','Lock'),
    ('LCK_M_RIn_S_LOW_PRIORITY','Lock'),
    ('LCK_M_RIn_U','Lock'),
    ('LCK_M_RIn_U_ABORT_BLOCKERS','Lock'),
    ('LCK_M_RIn_U_LOW_PRIORITY','Lock'),
    ('LCK_M_RIn_X','Lock'),
    ('LCK_M_RIn_X_ABORT_BLOCKERS','Lock'),
    ('LCK_M_RIn_X_LOW_PRIORITY','Lock'),
    ('LCK_M_RS_S','Lock'),
    ('LCK_M_RS_S_ABORT_BLOCKERS','Lock'),
    ('LCK_M_RS_S_LOW_PRIORITY','Lock'),
    ('LCK_M_RS_U','Lock'),
    ('LCK_M_RS_U_ABORT_BLOCKERS','Lock'),
    ('LCK_M_RS_U_LOW_PRIORITY','Lock'),
    ('LCK_M_RX_S','Lock'),
    ('LCK_M_RX_S_ABORT_BLOCKERS','Lock'),
    ('LCK_M_RX_S_LOW_PRIORITY','Lock'),
    ('LCK_M_RX_U','Lock'),
    ('LCK_M_RX_U_ABORT_BLOCKERS','Lock'),
    ('LCK_M_RX_U_LOW_PRIORITY','Lock'),
    ('LCK_M_RX_X','Lock'),
    ('LCK_M_RX_X_ABORT_BLOCKERS','Lock'),
    ('LCK_M_RX_X_LOW_PRIORITY','Lock'),
    ('LCK_M_S','Lock'),
    ('LCK_M_S_ABORT_BLOCKERS','Lock'),
    ('LCK_M_S_LOW_PRIORITY','Lock'),
    ('LCK_M_SCH_M','Lock'),
    ('LCK_M_SCH_M_ABORT_BLOCKERS','Lock'),
    ('LCK_M_SCH_M_LOW_PRIORITY','Lock'),
    ('LCK_M_SCH_S','Lock'),
    ('LCK_M_SCH_S_ABORT_BLOCKERS','Lock'),
    ('LCK_M_SCH_S_LOW_PRIORITY','Lock'),
    ('LCK_M_SIU','Lock'),
    ('LCK_M_SIU_ABORT_BLOCKERS','Lock'),
    ('LCK_M_SIU_LOW_PRIORITY','Lock'),
    ('LCK_M_SIX','Lock'),
    ('LCK_M_SIX_ABORT_BLOCKERS','Lock'),
    ('LCK_M_SIX_LOW_PRIORITY','Lock'),
    ('LCK_M_U','Lock'),
    ('LCK_M_U_ABORT_BLOCKERS','Lock'),
    ('LCK_M_U_LOW_PRIORITY','Lock'),
    ('LCK_M_UIX','Lock'),
    ('LCK_M_UIX_ABORT_BLOCKERS','Lock'),
    ('LCK_M_UIX_LOW_PRIORITY','Lock'),
    ('LCK_M_X','Lock'),
    ('LCK_M_X_ABORT_BLOCKERS','Lock'),
    ('LCK_M_X_LOW_PRIORITY','Lock'),
    ('LOGBUFFER','Tran Log IO'),
    ('LOGMGR','Tran Log IO'),
    ('LOGMGR_FLUSH','Tran Log IO'),
    ('LOGMGR_PMM_LOG','Tran Log IO'),
    ('LOGMGR_QUEUE','Idle'),
    ('LOGMGR_RESERVE_APPEND','Tran Log IO'),
    ('MEMORY_ALLOCATION_EXT','Memory'),
    ('MEMORY_GRANT_UPDATE','Memory'),
    ('MSQL_XACT_MGR_MUTEX','Transaction'),
    ('MSQL_XACT_MUTEX','Transaction'),
    ('MSSEARCH','Full Text Search'),
    ('NET_WAITFOR_PACKET','Network IO'),
    ('ONDEMAND_TASK_QUEUE','Idle'),
    ('PAGEIOLATCH_DT','Buffer IO'),
    ('PAGEIOLATCH_EX','Buffer IO'),
    ('PAGEIOLATCH_KP','Buffer IO'),
    ('PAGEIOLATCH_NL','Buffer IO'),
    ('PAGEIOLATCH_SH','Buffer IO'),
    ('PAGEIOLATCH_UP','Buffer IO'),
    ('PAGELATCH_DT','Buffer Latch'),
    ('PAGELATCH_EX','Buffer Latch'),
    ('PAGELATCH_KP','Buffer Latch'),
    ('PAGELATCH_NL','Buffer Latch'),
    ('PAGELATCH_SH','Buffer Latch'),
    ('PAGELATCH_UP','Buffer Latch'),
    ('POOL_LOG_RATE_GOVERNOR','Log Rate Governor'),
    ('PREEMPTIVE_ABR','Preemptive'),
    ('PREEMPTIVE_CLOSEBACKUPMEDIA','Preemptive'),
    ('PREEMPTIVE_CLOSEBACKUPTAPE','Preemptive'),
    ('PREEMPTIVE_CLOSEBACKUPVDIDEVICE','Preemptive'),
    ('PREEMPTIVE_CLUSAPI_CLUSTERRESOURCECONTROL','Preemptive'),
    ('PREEMPTIVE_COM_COCREATEINSTANCE','Preemptive'),
    ('PREEMPTIVE_COM_COGETCLASSOBJECT','Preemptive'),
    ('PREEMPTIVE_COM_CREATEACCESSOR','Preemptive'),
    ('PREEMPTIVE_COM_DELETEROWS','Preemptive'),
    ('PREEMPTIVE_COM_GETCOMMANDTEXT','Preemptive'),
    ('PREEMPTIVE_COM_GETDATA','Preemptive'),
    ('PREEMPTIVE_COM_GETNEXTROWS','Preemptive'),
    ('PREEMPTIVE_COM_GETRESULT','Preemptive'),
    ('PREEMPTIVE_COM_GETROWSBYBOOKMARK','Preemptive'),
    ('PREEMPTIVE_COM_LBFLUSH','Preemptive'),
    ('PREEMPTIVE_COM_LBLOCKREGION','Preemptive'),
    ('PREEMPTIVE_COM_LBREADAT','Preemptive'),
    ('PREEMPTIVE_COM_LBSETSIZE','Preemptive'),
    ('PREEMPTIVE_COM_LBSTAT','Preemptive'),
    ('PREEMPTIVE_COM_LBUNLOCKREGION','Preemptive'),
    ('PREEMPTIVE_COM_LBWRITEAT','Preemptive'),
    ('PREEMPTIVE_COM_QUERYINTERFACE','Preemptive'),
    ('PREEMPTIVE_COM_RELEASE','Preemptive'),
    ('PREEMPTIVE_COM_RELEASEACCESSOR','Preemptive'),
    ('PREEMPTIVE_COM_RELEASEROWS','Preemptive'),
    ('PREEMPTIVE_COM_RELEASESESSION','Preemptive'),
    ('PREEMPTIVE_COM_RESTARTPOSITION','Preemptive'),
    ('PREEMPTIVE_COM_SEQSTRMREAD','Preemptive'),
    ('PREEMPTIVE_COM_SEQSTRMREADANDWRITE','Preemptive'),
    ('PREEMPTIVE_COM_SETDATAFAILURE','Preemptive'),
    ('PREEMPTIVE_COM_SETPARAMETERINFO','Preemptive'),
    ('PREEMPTIVE_COM_SETPARAMETERPROPERTIES','Preemptive'),
    ('PREEMPTIVE_COM_STRMLOCKREGION','Preemptive'),
    ('PREEMPTIVE_COM_STRMSEEKANDREAD','Preemptive'),
    ('PREEMPTIVE_COM_STRMSEEKANDWRITE','Preemptive'),
    ('PREEMPTIVE_COM_STRMSETSIZE','Preemptive'),
    ('PREEMPTIVE_COM_STRMSTAT','Preemptive'),
    ('PREEMPTIVE_COM_STRMUNLOCKREGION','Preemptive'),
    ('PREEMPTIVE_CONSOLEWRITE','Preemptive'),
    ('PREEMPTIVE_CREATEPARAM','Preemptive'),
    ('PREEMPTIVE_DEBUG','Preemptive'),
    ('PREEMPTIVE_DFSADDLINK','Preemptive'),
    ('PREEMPTIVE_DFSLINKEXISTCHECK','Preemptive'),
    ('PREEMPTIVE_DFSLINKHEALTHCHECK','Preemptive'),
    ('PREEMPTIVE_DFSREMOVELINK','Preemptive'),
    ('PREEMPTIVE_DFSREMOVEROOT','Preemptive'),
    ('PREEMPTIVE_DFSROOTFOLDERCHECK','Preemptive'),
    ('PREEMPTIVE_DFSROOTINIT','Preemptive'),
    ('PREEMPTIVE_DFSROOTSHARECHECK','Preemptive'),
    ('PREEMPTIVE_DTC_ABORT','Preemptive'),
    ('PREEMPTIVE_DTC_ABORTREQUESTDONE','Preemptive'),
    ('PREEMPTIVE_DTC_BEGINTRANSACTION','Preemptive'),
    ('PREEMPTIVE_DTC_COMMITREQUESTDONE','Preemptive'),
    ('PREEMPTIVE_DTC_ENLIST','Preemptive'),
    ('PREEMPTIVE_DTC_PREPAREREQUESTDONE','Preemptive'),
    ('PREEMPTIVE_FILESIZEGET','Preemptive'),
    ('PREEMPTIVE_FSAOLEDB_ABORTTRANSACTION','Preemptive'),
    ('PREEMPTIVE_FSAOLEDB_COMMITTRANSACTION','Preemptive'),
    ('PREEMPTIVE_FSAOLEDB_STARTTRANSACTION','Preemptive'),
    ('PREEMPTIVE_FSRECOVER_UNCONDITIONALUNDO','Preemptive'),
    ('PREEMPTIVE_GETRMINFO','Preemptive'),
    ('PREEMPTIVE_HADR_LEASE_MECHANISM','Preemptive'),
    ('PREEMPTIVE_HTTP_EVENT_WAIT','Preemptive'),
    ('PREEMPTIVE_HTTP_REQUEST','Preemptive'),
    ('PREEMPTIVE_LOCKMONITOR','Preemptive'),
    ('PREEMPTIVE_MSS_RELEASE','Preemptive'),
    ('PREEMPTIVE_ODBCOPS','Preemptive'),
    ('PREEMPTIVE_OLE_UNINIT','Preemptive'),
    ('PREEMPTIVE_OLEDB_ABORTORCOMMITTRAN','Preemptive'),
    ('PREEMPTIVE_OLEDB_ABORTTRAN','Preemptive'),
    ('PREEMPTIVE_OLEDB_GETDATASOURCE','Preemptive'),
    ('PREEMPTIVE_OLEDB_GETLITERALINFO','Preemptive'),
    ('PREEMPTIVE_OLEDB_GETPROPERTIES','Preemptive'),
    ('PREEMPTIVE_OLEDB_GETPROPERTYINFO','Preemptive'),
    ('PREEMPTIVE_OLEDB_GETSCHEMALOCK','Preemptive'),
    ('PREEMPTIVE_OLEDB_JOINTRANSACTION','Preemptive'),
    ('PREEMPTIVE_OLEDB_RELEASE','Preemptive'),
    ('PREEMPTIVE_OLEDB_SETPROPERTIES','Preemptive'),
    ('PREEMPTIVE_OLEDBOPS','Preemptive'),
    ('PREEMPTIVE_OS_ACCEPTSECURITYCONTEXT','Preemptive'),
    ('PREEMPTIVE_OS_ACQUIRECREDENTIALSHANDLE','Preemptive'),
    ('PREEMPTIVE_OS_AUTHENTICATIONOPS','Preemptive'),
    ('PREEMPTIVE_OS_AUTHORIZATIONOPS','Preemptive'),
    ('PREEMPTIVE_OS_AUTHZGETINFORMATIONFROMCONTEXT','Preemptive'),
    ('PREEMPTIVE_OS_AUTHZINITIALIZECONTEXTFROMSID','Preemptive'),
    ('PREEMPTIVE_OS_AUTHZINITIALIZERESOURCEMANAGER','Preemptive'),
    ('PREEMPTIVE_OS_BACKUPREAD','Preemptive'),
    ('PREEMPTIVE_OS_CLOSEHANDLE','Preemptive'),
    ('PREEMPTIVE_OS_CLUSTEROPS','Preemptive'),
    ('PREEMPTIVE_OS_COMOPS','Preemptive'),
    ('PREEMPTIVE_OS_COMPLETEAUTHTOKEN','Preemptive'),
    ('PREEMPTIVE_OS_COPYFILE','Preemptive'),
    ('PREEMPTIVE_OS_CREATEDIRECTORY','Preemptive'),
    ('PREEMPTIVE_OS_CREATEFILE','Preemptive'),
    ('PREEMPTIVE_OS_CRYPTACQUIRECONTEXT','Preemptive'),
    ('PREEMPTIVE_OS_CRYPTIMPORTKEY','Preemptive'),
    ('PREEMPTIVE_OS_CRYPTOPS','Preemptive'),
    ('PREEMPTIVE_OS_DECRYPTMESSAGE','Preemptive'),
    ('PREEMPTIVE_OS_DELETEFILE','Preemptive'),
    ('PREEMPTIVE_OS_DELETESECURITYCONTEXT','Preemptive'),
    ('PREEMPTIVE_OS_DEVICEIOCONTROL','Preemptive'),
    ('PREEMPTIVE_OS_DEVICEOPS','Preemptive'),
    ('PREEMPTIVE_OS_DIRSVC_NETWORKOPS','Preemptive'),
    ('PREEMPTIVE_OS_DISCONNECTNAMEDPIPE','Preemptive'),
    ('PREEMPTIVE_OS_DOMAINSERVICESOPS','Preemptive'),
    ('PREEMPTIVE_OS_DSGETDCNAME','Preemptive'),
    ('PREEMPTIVE_OS_DTCOPS','Preemptive'),
    ('PREEMPTIVE_OS_ENCRYPTMESSAGE','Preemptive'),
    ('PREEMPTIVE_OS_FILEOPS','Preemptive'),
    ('PREEMPTIVE_OS_FINDFILE','Preemptive'),
    ('PREEMPTIVE_OS_FLUSHFILEBUFFERS','Preemptive'),
    ('PREEMPTIVE_OS_FORMATMESSAGE','Preemptive'),
    ('PREEMPTIVE_OS_FREECREDENTIALSHANDLE','Preemptive'),
    ('PREEMPTIVE_OS_FREELIBRARY','Preemptive'),
    ('PREEMPTIVE_OS_GENERICOPS','Preemptive'),
    ('PREEMPTIVE_OS_GETADDRINFO','Preemptive'),
    ('PREEMPTIVE_OS_GETCOMPRESSEDFILESIZE','Preemptive'),
    ('PREEMPTIVE_OS_GETDISKFREESPACE','Preemptive'),
    ('PREEMPTIVE_OS_GETFILEATTRIBUTES','Preemptive'),
    ('PREEMPTIVE_OS_GETFILESIZE','Preemptive'),
    ('PREEMPTIVE_OS_GETFINALFILEPATHBYHANDLE','Preemptive'),
    ('PREEMPTIVE_OS_GETLONGPATHNAME','Preemptive'),
    ('PREEMPTIVE_OS_GETPROCADDRESS','Preemptive'),
    ('PREEMPTIVE_OS_GETVOLUMENAMEFORVOLUMEMOUNTPOINT','Preemptive'),
    ('PREEMPTIVE_OS_GETVOLUMEPATHNAME','Preemptive'),
    ('PREEMPTIVE_OS_INITIALIZESECURITYCONTEXT','Preemptive'),
    ('PREEMPTIVE_OS_LIBRARYOPS','Preemptive'),
    ('PREEMPTIVE_OS_LOADLIBRARY','Preemptive'),
    ('PREEMPTIVE_OS_LOGONUSER','Preemptive'),
    ('PREEMPTIVE_OS_LOOKUPACCOUNTSID','Preemptive'),
    ('PREEMPTIVE_OS_MESSAGEQUEUEOPS','Preemptive'),
    ('PREEMPTIVE_OS_MOVEFILE','Preemptive'),
    ('PREEMPTIVE_OS_NETGROUPGETUSERS','Preemptive'),
    ('PREEMPTIVE_OS_NETLOCALGROUPGETMEMBERS','Preemptive'),
    ('PREEMPTIVE_OS_NETUSERGETGROUPS','Preemptive'),
    ('PREEMPTIVE_OS_NETUSERGETLOCALGROUPS','Preemptive'),
    ('PREEMPTIVE_OS_NETUSERMODALSGET','Preemptive'),
    ('PREEMPTIVE_OS_NETVALIDATEPASSWORDPOLICY','Preemptive'),
    ('PREEMPTIVE_OS_NETVALIDATEPASSWORDPOLICYFREE','Preemptive'),
    ('PREEMPTIVE_OS_OPENDIRECTORY','Preemptive'),
    ('PREEMPTIVE_OS_PDH_WMI_INIT','Preemptive'),
    ('PREEMPTIVE_OS_PIPEOPS','Preemptive'),
    ('PREEMPTIVE_OS_PROCESSOPS','Preemptive'),
    ('PREEMPTIVE_OS_QUERYCONTEXTATTRIBUTES','Preemptive'),
    ('PREEMPTIVE_OS_QUERYREGISTRY','Preemptive'),
    ('PREEMPTIVE_OS_QUERYSECURITYCONTEXTTOKEN','Preemptive'),
    ('PREEMPTIVE_OS_REMOVEDIRECTORY','Preemptive'),
    ('PREEMPTIVE_OS_REPORTEVENT','Preemptive'),
    ('PREEMPTIVE_OS_REVERTTOSELF','Preemptive'),
    ('PREEMPTIVE_OS_RSFXDEVICEOPS','Preemptive'),
    ('PREEMPTIVE_OS_SECURITYOPS','Preemptive'),
    ('PREEMPTIVE_OS_SERVICEOPS','Preemptive'),
    ('PREEMPTIVE_OS_SETENDOFFILE','Preemptive'),
    ('PREEMPTIVE_OS_SETFILEPOINTER','Preemptive'),
    ('PREEMPTIVE_OS_SETFILEVALIDDATA','Preemptive'),
    ('PREEMPTIVE_OS_SETNAMEDSECURITYINFO','Preemptive'),
    ('PREEMPTIVE_OS_SQLCLROPS','Preemptive'),
    ('PREEMPTIVE_OS_SQMLAUNCH','Preemptive'),
    ('PREEMPTIVE_OS_VERIFYSIGNATURE','Preemptive'),
    ('PREEMPTIVE_OS_VERIFYTRUST','Preemptive'),
    ('PREEMPTIVE_OS_VSSOPS','Preemptive'),
    ('PREEMPTIVE_OS_WAITFORSINGLEOBJECT','Preemptive'),
    ('PREEMPTIVE_OS_WINSOCKOPS','Preemptive'),
    ('PREEMPTIVE_OS_WRITEFILE','Preemptive'),
    ('PREEMPTIVE_OS_WRITEFILEGATHER','Preemptive'),
    ('PREEMPTIVE_OS_WSASETLASTERROR','Preemptive'),
    ('PREEMPTIVE_REENLIST','Preemptive'),
    ('PREEMPTIVE_RESIZELOG','Preemptive'),
    ('PREEMPTIVE_ROLLFORWARDREDO','Preemptive'),
    ('PREEMPTIVE_ROLLFORWARDUNDO','Preemptive'),
    ('PREEMPTIVE_SB_STOPENDPOINT','Preemptive'),
    ('PREEMPTIVE_SERVER_STARTUP','Preemptive'),
    ('PREEMPTIVE_SETRMINFO','Preemptive'),
    ('PREEMPTIVE_SHAREDMEM_GETDATA','Preemptive'),
    ('PREEMPTIVE_SNIOPEN','Preemptive'),
    ('PREEMPTIVE_SOSHOST','Preemptive'),
    ('PREEMPTIVE_SOSTESTING','Preemptive'),
    ('PREEMPTIVE_SP_SERVER_DIAGNOSTICS','Preemptive'),
    ('PREEMPTIVE_STARTRM','Preemptive'),
    ('PREEMPTIVE_STREAMFCB_CHECKPOINT','Preemptive'),
    ('PREEMPTIVE_STREAMFCB_RECOVER','Preemptive'),
    ('PREEMPTIVE_STRESSDRIVER','Preemptive'),
    ('PREEMPTIVE_TESTING','Preemptive'),
    ('PREEMPTIVE_TRANSIMPORT','Preemptive'),
    ('PREEMPTIVE_UNMARSHALPROPAGATIONTOKEN','Preemptive'),
    ('PREEMPTIVE_VSS_CREATESNAPSHOT','Preemptive'),
    ('PREEMPTIVE_VSS_CREATEVOLUMESNAPSHOT','Preemptive'),
    ('PREEMPTIVE_XE_CALLBACKEXECUTE','Preemptive'),
    ('PREEMPTIVE_XE_CX_FILE_OPEN','Preemptive'),
    ('PREEMPTIVE_XE_CX_HTTP_CALL','Preemptive'),
    ('PREEMPTIVE_XE_DISPATCHER','Preemptive'),
    ('PREEMPTIVE_XE_ENGINEINIT','Preemptive'),
    ('PREEMPTIVE_XE_GETTARGETSTATE','Preemptive'),
    ('PREEMPTIVE_XE_SESSIONCOMMIT','Preemptive'),
    ('PREEMPTIVE_XE_TARGETFINALIZE','Preemptive'),
    ('PREEMPTIVE_XE_TARGETINIT','Preemptive'),
    ('PREEMPTIVE_XE_TIMERRUN','Preemptive'),
    ('PREEMPTIVE_XETESTING','Preemptive'),
    ('PWAIT_HADR_ACTION_COMPLETED','Replication'),
    ('PWAIT_HADR_CHANGE_NOTIFIER_TERMINATION_SYNC','Replication'),
    ('PWAIT_HADR_CLUSTER_INTEGRATION','Replication'),
    ('PWAIT_HADR_FAILOVER_COMPLETED','Replication'),
    ('PWAIT_HADR_JOIN','Replication'),
    ('PWAIT_HADR_OFFLINE_COMPLETED','Replication'),
    ('PWAIT_HADR_ONLINE_COMPLETED','Replication'),
    ('PWAIT_HADR_POST_ONLINE_COMPLETED','Replication'),
    ('PWAIT_HADR_SERVER_READY_CONNECTIONS','Replication'),
    ('PWAIT_HADR_WORKITEM_COMPLETED','Replication'),
    ('PWAIT_HADRSIM','Replication'),
    ('PWAIT_RESOURCE_SEMAPHORE_FT_PARALLEL_QUERY_SYNC','Full Text Search'),
    ('QUERY_TRACEOUT','Tracing'),
    ('REPL_CACHE_ACCESS','Replication'),
    ('REPL_HISTORYCACHE_ACCESS','Replication'),
    ('REPL_SCHEMA_ACCESS','Replication'),
    ('REPL_TRANFSINFO_ACCESS','Replication'),
    ('REPL_TRANHASHTABLE_ACCESS','Replication'),
    ('REPL_TRANTEXTINFO_ACCESS','Replication'),
    ('REPLICA_WRITES','Replication'),
    ('REQUEST_FOR_DEADLOCK_SEARCH','Idle'),
    ('RESERVED_MEMORY_ALLOCATION_EXT','Memory'),
    ('RESOURCE_SEMAPHORE','Memory'),
    ('RESOURCE_SEMAPHORE_QUERY_COMPILE','Compilation'),
    ('SLEEP_BPOOL_FLUSH','Idle'),
    ('SLEEP_BUFFERPOOL_HELPLW','Idle'),
    ('SLEEP_DBSTARTUP','Idle'),
    ('SLEEP_DCOMSTARTUP','Idle'),
    ('SLEEP_MASTERDBREADY','Idle'),
    ('SLEEP_MASTERMDREADY','Idle'),
    ('SLEEP_MASTERUPGRADED','Idle'),
    ('SLEEP_MEMORYPOOL_ALLOCATEPAGES','Idle'),
    ('SLEEP_MSDBSTARTUP','Idle'),
    ('SLEEP_RETRY_VIRTUALALLOC','Idle'),
    ('SLEEP_SYSTEMTASK','Idle'),
    ('SLEEP_TASK','Idle'),
    ('SLEEP_TEMPDBSTARTUP','Idle'),
    ('SLEEP_WORKSPACE_ALLOCATEPAGE','Idle'),
    ('SOS_SCHEDULER_YIELD','CPU'),
    ('SQLCLR_APPDOMAIN','SQL CLR'),
    ('SQLCLR_ASSEMBLY','SQL CLR'),
    ('SQLCLR_DEADLOCK_DETECTION','SQL CLR'),
    ('SQLCLR_QUANTUM_PUNISHMENT','SQL CLR'),
    ('SQLTRACE_BUFFER_FLUSH','Idle'),
    ('SQLTRACE_FILE_BUFFER','Tracing'),
    ('SQLTRACE_FILE_READ_IO_COMPLETION','Tracing'),
    ('SQLTRACE_FILE_WRITE_IO_COMPLETION','Tracing'),
    ('SQLTRACE_INCREMENTAL_FLUSH_SLEEP','Idle'),
    ('SQLTRACE_PENDING_BUFFER_WRITERS','Tracing'),
    ('SQLTRACE_SHUTDOWN','Tracing'),
    ('SQLTRACE_WAIT_ENTRIES','Idle'),
    ('THREADPOOL','Worker Thread'),
    ('TRACE_EVTNOTIF','Tracing'),
    ('TRACEWRITE','Tracing'),
    ('TRAN_MARKLATCH_DT','Transaction'),
    ('TRAN_MARKLATCH_EX','Transaction'),
    ('TRAN_MARKLATCH_KP','Transaction'),
    ('TRAN_MARKLATCH_NL','Transaction'),
    ('TRAN_MARKLATCH_SH','Transaction'),
    ('TRAN_MARKLATCH_UP','Transaction'),
    ('TRANSACTION_MUTEX','Transaction'),
    ('WAIT_FOR_RESULTS','User Wait'),
    ('WAITFOR','User Wait'),
    ('WRITE_COMPLETION','Other Disk IO'),
    ('WRITELOG','Tran Log IO'),
    ('XACT_OWN_TRANSACTION','Transaction'),
    ('XACT_RECLAIM_SESSION','Transaction'),
    ('XACTLOCKINFO','Transaction'),
    ('XACTWORKSPACE_MUTEX','Transaction'),
    ('XE_DISPATCHER_WAIT','Idle'),
    ('XE_TIMER_EVENT','Idle')) AS wc(wait_type, wait_category)
        ON ws.wait_type = wc.wait_type
WHERE
    ws.wait_type NOT IN (
        N'BROKER_EVENTHANDLER', N'BROKER_RECEIVE_WAITFOR', N'BROKER_TASK_STOP',
		N'BROKER_TO_FLUSH', N'BROKER_TRANSMITTER', N'CHECKPOINT_QUEUE',
        N'CHKPT', N'CLR_AUTO_EVENT', N'CLR_MANUAL_EVENT', N'CLR_SEMAPHORE',
        N'DBMIRROR_DBM_EVENT', N'DBMIRROR_EVENTS_QUEUE', N'DBMIRROR_WORKER_QUEUE',
		N'DBMIRRORING_CMD', N'DIRTY_PAGE_POLL', N'DISPATCHER_QUEUE_SEMAPHORE',
        N'EXECSYNC', N'FSAGENT', N'FT_IFTS_SCHEDULER_IDLE_WAIT', N'FT_IFTSHC_MUTEX',
        N'HADR_CLUSAPI_CALL', N'HADR_FILESTREAM_IOMGR_IOCOMPLETION', N'HADR_LOGCAPTURE_WAIT', 
		N'HADR_NOTIFICATION_DEQUEUE', N'HADR_TIMER_TASK', N'HADR_WORK_QUEUE',
        N'KSOURCE_WAKEUP', N'LAZYWRITER_SLEEP', N'LOGMGR_QUEUE', 
		N'MEMORY_ALLOCATION_EXT', N'ONDEMAND_TASK_QUEUE',
		N'PARALLEL_REDO_WORKER_WAIT_WORK',
		N'PREEMPTIVE_HADR_LEASE_MECHANISM', N'PREEMPTIVE_SP_SERVER_DIAGNOSTICS',
		N'PREEMPTIVE_OS_LIBRARYOPS', N'PREEMPTIVE_OS_COMOPS', N'PREEMPTIVE_OS_CRYPTOPS',
		N'PREEMPTIVE_OS_PIPEOPS', N'PREEMPTIVE_OS_AUTHENTICATIONOPS',
		N'PREEMPTIVE_OS_GENERICOPS', N'PREEMPTIVE_OS_VERIFYTRUST',
		N'PREEMPTIVE_OS_FILEOPS', N'PREEMPTIVE_OS_DEVICEOPS', N'PREEMPTIVE_OS_QUERYREGISTRY',
		N'PREEMPTIVE_OS_WRITEFILE',
		N'PREEMPTIVE_XE_CALLBACKEXECUTE', N'PREEMPTIVE_XE_DISPATCHER',
		N'PREEMPTIVE_XE_GETTARGETSTATE', N'PREEMPTIVE_XE_SESSIONCOMMIT',
		N'PREEMPTIVE_XE_TARGETINIT', N'PREEMPTIVE_XE_TARGETFINALIZE',
        N'PWAIT_ALL_COMPONENTS_INITIALIZED', N'PWAIT_DIRECTLOGCONSUMER_GETNEXT',
		N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
		N'QDS_ASYNC_QUEUE',
        N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP', N'REQUEST_FOR_DEADLOCK_SEARCH',
		N'RESOURCE_QUEUE', N'SERVER_IDLE_CHECK', N'SLEEP_BPOOL_FLUSH', N'SLEEP_DBSTARTUP',
		N'SLEEP_DCOMSTARTUP', N'SLEEP_MASTERDBREADY', N'SLEEP_MASTERMDREADY',
        N'SLEEP_MASTERUPGRADED', N'SLEEP_MSDBSTARTUP', N'SLEEP_SYSTEMTASK', N'SLEEP_TASK',
        N'SLEEP_TEMPDBSTARTUP', N'SNI_HTTP_ACCEPT', N'SP_SERVER_DIAGNOSTICS_SLEEP',
		N'SQLTRACE_BUFFER_FLUSH', N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', N'SQLTRACE_WAIT_ENTRIES',
		N'WAIT_FOR_RESULTS', N'WAITFOR', N'WAITFOR_TASKSHUTDOWN', N'WAIT_XTP_HOST_WAIT',
		N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG', N'WAIT_XTP_CKPT_CLOSE', N'WAIT_XTP_RECOVERY',
		N'XE_BUFFERMGR_ALLPROCESSED_EVENT', N'XE_DISPATCHER_JOIN',
        N'XE_DISPATCHER_WAIT', N'XE_LIVE_TARGET_TVF', N'XE_TIMER_EVENT',N'VDI_CLIENT_OTHER',
        N'XTP_PREEMPTIVE_TASK')
GROUP BY
    COALESCE(wc.wait_category,ws.wait_type)
HAVING 
    COUNT(*) > 1
ORDER BY
    COUNT(*) DESC,
    max(ws.wait_duration_ms) DESC
FOR XML PATH(''), TYPE
).value('.','nvarchar(max)')

--== Print what we got
SELECT
REPLACE(REPLACE(REPLACE(REPLACE(
REPLACE(REPLACE(REPLACE(REPLACE(
REPLACE(REPLACE(REPLACE(REPLACE(
REPLACE(REPLACE(REPLACE(REPLACE(
REPLACE(REPLACE(REPLACE(REPLACE(
REPLACE(REPLACE(REPLACE(REPLACE(
REPLACE(REPLACE(REPLACE(REPLACE(
REPLACE(
--==
'
      SQL Server Version: {{24}}
     Current Server Time: {{15}}
              Last Start: {{17}}
            Agent Status: {{31}}
      CPU % (15m/60m/4h): {{25}}/{{26}}/{{27}}
     Average Load Factor: {{0}}
               CPU Count: {{7}}
                  MAXDOP: {{16}}
      Server Memory (GB): {{18}}
         Max Memory (GB): {{29}}
   Pending Memory Grants: {{14}}
                     PLE: {{23}}
          TempDB Free MB: {{1}}
           TempDB Free %: {{2}}
     Version Store Usage: {{8}}
          Total Sessions: {{3}}
         Active Sessions: {{4}}
        Blocked Sessions: {{19}}
    Max Session Duration: {{10}}
Worker Threads (Cur/Max): {{5}}/{{6}}
       Avg. Read Latency: {{20}}
      Avg. Write Latency: {{21}}

Wait Categories (Top 5):
{{32}}
Memory Clerk Detail (Top 5, GB):
{{30}}
Availability Group Stats:
{{28}}
Mount Point Capacity (Mount Point: TotalGB, FreeGB, FreePCT)
{{22}}
'
--==
,'{{0}}',ISNULL(@loadFactor,0))
,'{{1}}',ISNULL(@freeTempMB,0))
,'{{2}}',ISNULL(@freeTempPct,0))
,'{{3}}',ISNULL(@sessionTotal,0))
,'{{4}}',ISNULL(@sessionActive,0))
,'{{5}}',ISNULL(@workers,0))
,'{{6}}',ISNULL(@maxWorkers,0))
,'{{7}}',ISNULL(@cpuCount,0))
,'{{8}}',ISNULL(@tempDBVersionStore,0))
,'{{10}}',ISNULL(@maxDuration,0))
,'{{19}}',ISNULL(@blockedSessions,0))
,'{{14}}',ISNULL(@pendingMemoryGrants,0))
,'{{15}}',CONVERT(VARCHAR,@serverTime,120))
,'{{16}}',ISNULL(@maxDop,0))
,'{{17}}',CONVERT(VARCHAR,@serverStartTime,120))
,'{{18}}',ISNULL(@serverMemoryGB,0))
,'{{20}}',ISNULL(@readLatency,0))
,'{{21}}',ISNULL(@writeLatency,0))
,'{{22}}',ISNULL(@mountPointData,''))
,'{{23}}',ISNULL(@ple,0))
,'{{24}}',REPLACE(REPLACE(SUBSTRING(@@VERSION,1,PATINDEX('% - %',@@VERSION)),'Microsoft ',''),'Server ','') + ISNULL(' ' + CAST(SERVERPROPERTY ('productlevel') AS VARCHAR),'') + ISNULL(' - ' + CAST(SERVERPROPERTY('ProductUpdateLevel') AS VARCHAR),'') + ISNULL(' - ' + CAST(SERVERPROPERTY ('edition') AS VARCHAR),''))
,'{{25}}',@avg15)
,'{{26}}',@avg60)
,'{{27}}',@avg240)
,'{{28}}',ISNULL(@AGHealth,'    NA
'))
,'{{29}}',@maxMemoryGB)
,'{{30}}',@memoryDetail)
,'{{31}}',@AgentStatus)
,'{{32}}',ISNULL(@waitData,'  No waiting tasks.
')) AS result;
