{-# LANGUAGE ForeignFunctionInterface, EmptyDataDecls, OverloadedStrings, ScopedTypeVariables #-}
module Database.PQ ( Connection
                   , ConnStatus(..)
                   , Result
                   , ResultStatus(..)
                   , Format(..)
                   , PrintOpt(..)

                   , connectdb
                   , setClientEncoding
                   , consumeInput
                   , errorMessage
                   , escapeByteaConn
                   , escapeStringConn
                   , exec
                   , execParams
                   , execPrepared
                   , getResult
                   , isBusy
                   , prepare
                   , reset
                   , sendPrepare
                   , sendQuery
                   , sendQueryParams
                   , sendQueryPrepared
                   , status

                   , resultStatus
                   , resultErrorMessage
                   , ntuples
                   , nfields
                   , fname
                   , fnumber
                   , ftable
                   , ftablecol
                   , fformat
                   , ftype
                   , fmod
                   , fsize
                   , getvalue
                   , getisnull
                   , getlength
                   , print
                   )
where

#include <libpq-fe.h>

import Prelude hiding ( print )
import Control.Monad ( when )
import Foreign
import Foreign.Ptr
import Foreign.C.Types
import Foreign.C.String
import GHC.Conc ( threadWaitRead, threadWaitWrite)
import System.Posix.Types ( Fd(..) )
import Data.List ( foldl' )
import System.IO ( Handle )
import GHC.Handle ( hDuplicate )
import System.Posix.IO ( handleToFd )

import qualified Data.ByteString.Char8 as Char8
import qualified Data.ByteString.Unsafe as B
import qualified Data.ByteString.Internal as B (fromForeignPtr)
import qualified Data.ByteString as B

data Format = Text | Binary deriving Enum

-- | 'Connection' encapsulates a connection to the backend.
newtype Connection = Conn (ForeignPtr PGconn) deriving (Eq, Show)
data PGconn

-- | 'Result' encapsulates the result of a query (or more precisely,
-- of a single SQL command --- a query string given to 'sendQuery' can
-- contain multiple commands and thus return multiple instances of
-- 'Result'.
newtype Result = Result (ForeignPtr PGresult) deriving (Eq, Show)
data PGresult


-- | Obtains the file descriptor number of the connection socket to
-- the server.
connFd :: Connection
       -> IO (Maybe Fd)
connFd (Conn conn) =
    do cFd <- withForeignPtr conn c_PQsocket
       return $ case cFd of
                  -1 -> Nothing
                  _ -> Just $ Fd cFd

-- | Returns the error message most recently generated by an operation
-- on the connection.
errorMessage :: Connection
             -> IO B.ByteString
errorMessage (Conn conn) =
    B.packCString =<< withForeignPtr conn c_PQerrorMessage


-- | Escapes a string for use within an SQL command. This is useful
-- when inserting data values as literal constants in SQL
-- commands. Certain characters (such as quotes and backslashes) must
-- be escaped to prevent them from being interpreted specially by the
-- SQL parser.
escapeStringConn :: Connection
                 -> B.ByteString
                 -> IO B.ByteString
escapeStringConn connection@(Conn c) bs =
    withForeignPtr c $ \conn -> do
      B.unsafeUseAsCStringLen bs $ \(from, bslen) -> do
        alloca $ \err -> do
          to <- mallocBytes (bslen*2+1)
          num <- c_PQescapeStringConn conn to from (fromIntegral bslen) err
          stat <- peek err
          case stat of
            0 -> do tofp <- newForeignPtr finalizerFree to
                    return $ B.fromForeignPtr tofp 0 (fromIntegral num)

            _ -> do free to
                    failErrorMessage connection


-- | Escapes binary data for use within an SQL command with the type
-- bytea. As with 'escapeStringConn', this is only used when inserting
-- data directly into an SQL command string.
escapeByteaConn :: Connection
                -> B.ByteString
                -> IO B.ByteString
escapeByteaConn connection@(Conn c) bs =
    withForeignPtr c $ \conn -> do
      B.unsafeUseAsCStringLen bs $ \(from, bslen) -> do
        alloca $ \to_length -> do
          to <- c_PQescapeByteaConn conn from (fromIntegral bslen) to_length
          if to == nullPtr
            then failErrorMessage connection
            else do tofp <- newForeignPtr p_PQfreemem to
                    l <- peek to_length
                    return $ B.fromForeignPtr tofp 0 ((fromIntegral l) - 1)


-- | Helper function that calls fail with the result of errorMessage
failErrorMessage :: Connection
                 -> IO a
failErrorMessage conn =
    do msg <- errorMessage conn
       fail $ Char8.unpack msg


data ConnStatus
    = ConnectionOk                 -- ^ The 'Connection' is ready.
    | ConnectionBad                -- ^ The connection procedure has failed.
    | ConnectionStarted            -- ^ Waiting for connection to be made.
    | ConnectionMade               -- ^ Connection OK; waiting to send.
    | ConnectionAwaitingResponse   -- ^ Waiting for a response from the server.
    | ConnectionAuthOk             -- ^ Received authentication;
                                   -- waiting for backend start-up to
                                   -- finish.
    | ConnectionSetEnv             -- ^ Negotiating environment-driven
                                   -- parameter settings.
    | ConnectionSSLStartup         -- ^ Negotiating SSL encryption.
    | ConnectionOther Int          -- ^ Unknown connection state
      deriving Show


-- | Returns the status of the connection.
status :: Connection
       -> IO ConnStatus
status (Conn conn) =
    withForeignPtr conn (return . status')
    where
      status' connPtr =
          case c_PQstatus connPtr of
            (#const CONNECTION_OK)               -> ConnectionOk
            (#const CONNECTION_BAD)              -> ConnectionBad
            (#const CONNECTION_STARTED)          -> ConnectionStarted
            (#const CONNECTION_MADE)             -> ConnectionMade
            (#const CONNECTION_AWAITING_RESPONSE)-> ConnectionAwaitingResponse
            (#const CONNECTION_AUTH_OK)          -> ConnectionAuthOk
            (#const CONNECTION_SETENV)           -> ConnectionSetEnv
            (#const CONNECTION_SSL_STARTUP)      -> ConnectionSSLStartup
            --(#const CONNECTION_NEEDED)           -> ConnectionNeeded
            c                                    -> ConnectionOther $ fromEnum c


-- | Makes a new connection to the database server.
connectdb :: B.ByteString -- ^ Connection info
          -> IO Connection
connectdb connStr =
    do conn <- connectStart connStr
       poll conn
       return conn
    where
      poll conn =
          do stat <- connectPoll conn
             case stat of
               PollingReading -> connWaitRead conn poll
               PollingOk      -> return ()
               PollingFailed  -> failErrorMessage conn
               PollingWriting -> connWaitWrite conn poll


-- | Resets the communication channel to the server.
reset :: Connection
      -> IO ()
reset connection =
    do resetStart connection
       poll connection
    where
      poll conn =
          do stat <- resetPoll conn
             case stat of
               PollingReading -> connWaitRead conn poll
               PollingOk      -> return ()
               PollingFailed  -> failErrorMessage conn
               PollingWriting -> connWaitWrite conn poll


-- | Sets the client encoding.
setClientEncoding :: Connection -> B.ByteString -> IO ()
setClientEncoding (Conn conn) enc =
    do stat <- withForeignPtr conn $ \c -> do
                 B.useAsCString enc $ \s -> do
                   c_PQsetClientEncoding c s

       case stat of
         0 -> return ()
         _ -> failErrorMessage (Conn conn)


-- | Submits a command to the server and waits for the result.
exec :: Connection
     -> B.ByteString
     -> IO Result
exec connection query =
    do sendQuery connection query
       flush connection
       Just result <- connWaitRead connection getResult
       throwAwaySubsequentResults connection
       return result


-- | Submits a command to the server and waits for the result, with
-- the ability to pass parameters separately from the SQL command
-- text.
execParams :: Connection
           -> B.ByteString
           -> [Maybe (Oid, B.ByteString, Format)]
           -> Format
           -> IO Result
execParams conn statement params resultFormat =
    do sendQueryParams conn statement params resultFormat
       flush conn
       Just result <- connWaitRead conn getResult
       throwAwaySubsequentResults conn
       return result


-- | Submits a request to create a prepared statement with the given
-- parameters, and waits for completion.
prepare :: Connection
        -> B.ByteString
        -> B.ByteString
        -> Maybe [Oid]
        -> IO Result
prepare connection stmtName query mParamTypes =
    do sendPrepare connection stmtName query mParamTypes
       flush connection
       Just result <- connWaitRead connection getResult
       throwAwaySubsequentResults connection
       return result


-- | Sends a request to execute a prepared statement with given
-- parameters, and waits for the result.
execPrepared :: Connection
             -> B.ByteString
             -> [Maybe (B.ByteString, Format)]
             -> Format
             -> IO Result
execPrepared connection stmtName mPairs binary_result =
    do sendQueryPrepared connection stmtName mPairs binary_result
       flush connection
       Just result <- connWaitRead connection getResult
       throwAwaySubsequentResults connection
       return result


-- | Submits a command and separate parameters to the server without
-- waiting for the result(s).
sendQueryParams :: Connection
                -> B.ByteString
                -> [Maybe (Oid, B.ByteString, Format)]
                -> Format
                -> IO ()
sendQueryParams connection@(Conn conn) statement params rFmt =
    do let (oids, values, lengths, formats) =
               foldl' accum ([],[],[],[]) $ reverse params
           c_lengths = map toEnum lengths :: [CInt]
           n = toEnum $ length params
           f = toEnum $ fromEnum rFmt
       stat <- withForeignPtr conn $ \c -> do
                 B.useAsCString statement $ \s -> do
                   withArray oids $ \ts -> do
                     withMany (maybeWith B.useAsCString) values $ \c_values ->
                       withArray c_values $ \vs -> do
                         withArray c_lengths $ \ls -> do
                           withArray formats $ \fs -> do
                             c_PQsendQueryParams c s n ts vs ls fs f

       case stat of
         1 -> return ()
         _ -> failErrorMessage connection

    where
      accum (a,b,c,d) Nothing = ( 0:a
                                , Nothing:b
                                , 0:c
                                , 0:d
                                )
      accum (a,b,c,d) (Just (t,v,f)) = ( t:a
                                       , (Just v):b
                                       , (B.length v):c
                                       , (toEnum $ fromEnum f):d
                                       )


-- | Sends a request to create a prepared statement with the given
-- parameters, without waiting for completion.
sendPrepare :: Connection
            -> B.ByteString
            -> B.ByteString
            -> Maybe [Oid]
            -> IO ()
sendPrepare connection@(Conn conn) stmtName query mParamTypes =
    do stat <- withForeignPtr conn $ \c -> do
                 B.useAsCString stmtName $ \s -> do
                   B.useAsCString query $ \q -> do
                     maybeWith withArray mParamTypes $ \o -> do
                       let l = maybe 0 (toEnum . length) mParamTypes
                       c_PQsendPrepare c s q l o
       case stat of
         1 -> return ()
         _ -> failErrorMessage connection


-- | Sends a request to execute a prepared statement with given
-- parameters, without waiting for the result(s).
sendQueryPrepared :: Connection
                  -> B.ByteString
                  -> [Maybe (B.ByteString, Format)]
                  -> Format
                  -> IO ()
sendQueryPrepared (Conn conn) stmtName mPairs rFmt =
    do let (values, lengths, formats) = foldl' accum ([],[],[]) $ reverse mPairs
           c_lengths = map toEnum lengths :: [CInt]
           n = toEnum $ length mPairs
           f = toEnum $ fromEnum rFmt
       stat <- withForeignPtr conn $ \c -> do
                 B.useAsCString stmtName $ \s -> do
                   withMany (maybeWith B.useAsCString) values $ \c_values ->
                     withArray c_values $ \vs -> do
                       withArray c_lengths $ \ls -> do
                         withArray formats $ \fs -> do
                           c_PQsendQueryPrepared c s n vs ls fs f


       case stat of
         1 -> return ()
         _ -> failErrorMessage (Conn conn)

    where
      accum (a,b,c) Nothing       = ( Nothing:a
                                    , 0:b
                                    , 0:c
                                    )
      accum (a,b,c) (Just (v, f)) = ( (Just v):a
                                    , (B.length v):b
                                    , (toEnum $ fromEnum f):c
                                    )


-- | Helper function to consume and ignore all results available
-- results
throwAwaySubsequentResults :: Connection
                           -> IO ()
throwAwaySubsequentResults connection =
    do readData connection
       result <- getResult connection
       case result of
         Nothing -> return ()
         Just _ -> throwAwaySubsequentResults connection
    where
      readData conn =
          do consumeInput conn
             busy <- isBusy conn
             if busy
                 then connWaitRead conn readData
                 else return ()


-- | Helper function for using 'threadWaitRead' with a 'Connection'
connWaitRead :: Connection
             -> (Connection -> IO a)
             -> IO a
connWaitRead conn ioa =
    do fd <- connFd conn
       maybe (return ()) threadWaitRead fd
       ioa conn


-- | Helper function for using 'threadWaitWrite' with a 'Connection'
connWaitWrite :: Connection
              -> (Connection -> IO a)
              -> IO a
connWaitWrite conn ioa =
    do fd <- connFd conn
       maybe (return ()) threadWaitWrite fd
       ioa conn


connectStart :: B.ByteString
             -> IO Connection
connectStart connStr =
    do connPtr <- B.useAsCString connStr c_PQconnectStart
       if connPtr == nullPtr
           then fail $ "PQconnectStart failed to allocate memory"
           else Conn `fmap` newForeignPtr p_PQfinish connPtr


data PollingStatus
    = PollingFailed
    | PollingReading
    | PollingWriting
    | PollingOk deriving Show


connectPoll :: Connection
            -> IO PollingStatus
connectPoll (Conn conn) =
    withForeignPtr conn $ \connPtr -> do
      code <- c_PQconnectPoll connPtr
      case code of
        (#const PGRES_POLLING_READING) -> return PollingReading
        (#const PGRES_POLLING_OK)      -> return PollingOk
        (#const PGRES_POLLING_FAILED)  -> return PollingFailed
        (#const PGRES_POLLING_WRITING) -> return PollingWriting
        _ -> fail $ "PQconnectPoll returned " ++ show code


resetStart :: Connection
           -> IO ()
resetStart (Conn conn) =
    withForeignPtr conn $ \connPtr -> do
      result <- c_PQresetStart connPtr
      case result of
        1 -> return ()
        _ -> fail $ "PQresetStart returned " ++ show result


resetPoll :: Connection
          -> IO PollingStatus
resetPoll (Conn conn) =
    withForeignPtr conn $ \connPtr -> do
      code <- c_PQresetPoll connPtr
      case code of
        (#const PGRES_POLLING_READING) -> return PollingReading
        (#const PGRES_POLLING_OK)      -> return PollingOk
        (#const PGRES_POLLING_FAILED)  -> return PollingFailed
        (#const PGRES_POLLING_WRITING) -> return PollingWriting
        _ -> fail $ "PQresetPoll returned " ++ show code


sendQuery :: Connection
          -> B.ByteString
          -> IO ()
sendQuery connection@(Conn conn) query =
    do stat <- withForeignPtr conn $ \p -> do
                 B.useAsCString query (c_PQsendQuery p)
       case stat of
         1 -> return ()
         _ -> failErrorMessage connection


flush :: Connection
      -> IO ()
flush connection@(Conn conn) =
    do stat <- withForeignPtr conn c_PQflush
       case stat of
         0 -> return ()
         1 -> connWaitWrite (Conn conn) flush
         _ -> failErrorMessage connection


-- | If input is available from the server, consume it.
consumeInput :: Connection
             -> IO ()
consumeInput connection@(Conn conn) =
    do stat <- withForeignPtr conn c_PQconsumeInput
       case stat of
         1 -> return ()
         _ -> failErrorMessage connection


-- | Returns True if a command is busy, that is, getResult would block
-- waiting for input. A False return indicates that getResult can be
-- called with assurance of not blocking.
isBusy :: Connection
       -> IO Bool
isBusy (Conn conn) =
    do stat <- withForeignPtr conn c_PQisBusy
       case stat of
         1 -> return True
         0 -> return False
         _ -> fail $ "PQisBusy returned unexpected result " ++ show stat


-- | Waits for the next result from a prior sendQuery, sendQueryParams,
-- sendPrepare, or sendQueryPrepared call, and returns it. A null
-- pointer is returned when the command is complete and there will be
-- no more results.
getResult :: Connection
          -> IO (Maybe Result)
getResult (Conn conn) =
    do resPtr <- withForeignPtr conn c_PQgetResult
       if resPtr == nullPtr
           then return Nothing
           else (Just . Result) `fmap` newForeignPtr p_PQclear resPtr


data ResultStatus = EmptyQuery
                  | CommandOk
                  | TuplesOk
                  | CopyOut
                  | CopyIn
                  | BadResponse
                  | NonfatalError
                  | FatalError deriving Show


-- | Returns the result status of the command.
resultStatus :: Result
             -> IO ResultStatus
resultStatus (Result res) =
      withForeignPtr res $ \resPtr -> do
          case c_PQresultStatus resPtr of
            (#const PGRES_EMPTY_QUERY)    -> return EmptyQuery
            (#const PGRES_COMMAND_OK)     -> return CommandOk
            (#const PGRES_TUPLES_OK)      -> return TuplesOk
            (#const PGRES_COPY_OUT)       -> return CopyOut
            (#const PGRES_COPY_IN)        -> return CopyIn
            (#const PGRES_BAD_RESPONSE)   -> return BadResponse
            (#const PGRES_NONFATAL_ERROR) -> return NonfatalError
            (#const PGRES_FATAL_ERROR)    -> return FatalError
            s -> fail $ "Unexpected result from PQresultStatus" ++ show s


-- | Returns the number of rows (tuples) in the query result. Because
-- it returns an integer result, large result sets might overflow the
-- return value on 32-bit operating systems.
ntuples :: Result
        -> IO Int
ntuples (Result res) = withForeignPtr res (return . fromEnum . c_PQntuples)


-- | Returns the number of columns (fields) in each row of the query
-- result.
nfields :: Result
        -> IO Int
nfields (Result res) = withForeignPtr res (return . fromEnum . c_PQnfields)


-- | Returns the column name associated with the given column
-- number. Column numbers start at 0.
fname :: Result
      -> Int
      -> IO B.ByteString
fname result@(Result res) colNum =
      do nf <- nfields result
         when (colNum < 0 || colNum >= nf) (failure nf)
         cs <- withForeignPtr res $ (flip c_PQfname) $ toEnum colNum
         if cs == nullPtr
           then failure nf
           else B.packCString cs
    where
      failure nf = fail ("column number " ++
                         show colNum ++
                         " is out of range 0.." ++
                         show (nf - 1))


-- | Returns the column number associated with the given column name.
fnumber :: Result
        -> B.ByteString
        -> IO (Maybe Int)
fnumber (Result res) columnName =
    do num <- withForeignPtr res $ \resPtr -> do
                B.useAsCString columnName $ \cColumnName -> do
                  c_PQfnumber resPtr cColumnName
       return $ if num == -1
                  then Nothing
                  else Just $ fromIntegral num


-- | Returns the OID of the table from which the given column was
-- fetched. Column numbers start at 0.
ftable :: Result
       -> Int
       -> IO Oid
ftable (Result res) columnNumber =
    withForeignPtr res $ \ptr -> do
      c_PQftable ptr $ fromIntegral columnNumber


-- | Returns the column number (within its table) of the column making
-- up the specified query result column. Query-result column numbers
-- start at 0, but table columns have nonzero numbers.
ftablecol :: Result
          -> Int
          -> IO Int
ftablecol (Result res) columnNumber =
    fmap fromIntegral $ withForeignPtr res $ \ptr -> do
      c_PQftablecol ptr $ fromIntegral columnNumber


-- | Returns the 'Format' of the given column. Column numbers start at
-- 0.
fformat :: Result
        -> Int
        -> IO Format
fformat (Result res) columnNumber =
    fmap (toEnum . fromIntegral) $ withForeignPtr res $ \ptr -> do
      c_PQfformat ptr $ fromIntegral columnNumber


-- | Returns the data type associated with the given column
-- number. The 'Oid' returned is the internal OID number of the
-- type. Column numbers start at 0.
--
-- You can query the system table pg_type to obtain the names and
-- properties of the various data types. The OIDs of the built-in data
-- types are defined in the file src/include/catalog/pg_type.h in the
-- source tree.
ftype :: Result
      -> Int
      -> IO Oid
ftype (Result res) columnNumber =
    withForeignPtr res $ \ptr -> do
      c_PQftype ptr $ fromIntegral columnNumber


-- | Returns the type modifier of the column associated with the given
-- column number. Column numbers start at 0.
--
-- The interpretation of modifier values is type-specific; they
-- typically indicate precision or size limits. The value -1 is used
-- to indicate "no information available". Most data types do not use
-- modifiers, in which case the value is always -1.
fmod :: Result
     -> Int
     -> IO Int
fmod (Result res) columnNumber =
    fmap fromIntegral $ withForeignPtr res $ \ptr -> do
      c_PQfmod ptr $ fromIntegral columnNumber


-- | Returns the size in bytes of the column associated with the given
-- column number. Column numbers start at 0.
--
-- 'fsize' returns the space allocated for this column in a database
-- row, in other words the size of the server's internal
-- representation of the data type. (Accordingly, it is not really
-- very useful to clients.) A negative value indicates the data type
-- is variable-length.
fsize :: Result
      -> Int
      -> IO Int
fsize (Result res) columnNumber =
    fmap fromIntegral $ withForeignPtr res $ \ptr -> do
      c_PQfsize ptr $ fromIntegral columnNumber


-- | Returns a single field value of one row of a PGresult. Row and
-- column numbers start at 0.
--
-- For convenience, this binding uses 'getisnull' and 'getlength' to
-- help construct the result.
getvalue :: Result
         -> Int
         -> Int
         -> IO (Maybe B.ByteString)
getvalue (Result res) rowNumber columnNumber = do
  let row = fromIntegral rowNumber
      col = fromIntegral columnNumber
  withForeignPtr res $ \ptr -> do
    isnull <- c_PQgetisnull ptr row col
    if toEnum $ fromIntegral isnull
      then return $ Nothing

      else do cstr <- c_PQgetvalue ptr row col
              len <- c_PQgetlength ptr row col
              fmap Just $ B.packCStringLen (cstr, fromIntegral len)


-- | Tests a field for a null value. Row and column numbers start at
-- 0.
getisnull :: Result
          -> Int
          -> Int
          -> IO Bool
getisnull (Result res) rowNumber columnNumber =
    fmap (toEnum . fromIntegral) $ withForeignPtr res $ \ptr -> do
      c_PQgetisnull ptr (fromIntegral rowNumber) (fromIntegral columnNumber)


-- | Returns the actual length of a field value in bytes. Row and
-- column numbers start at 0.
--
-- This is the actual data length for the particular data value, that
-- is, the size of the object pointed to by 'getvalue'. For text data
-- format this is the same as strlen(). For binary format this is
-- essential information. Note that one should not rely on 'fsize' to
-- obtain the actual data length.
getlength :: Result
          -> Int
          -> Int
          -> IO Int
getlength (Result res) rowNumber columnNumber =
    fmap fromIntegral $ withForeignPtr res $ \ptr -> do
      c_PQgetlength ptr (fromIntegral rowNumber) (fromIntegral columnNumber)


data PrintOpt = PrintOpt {
      poHeader     :: Bool -- ^ print output field headings and row count
    , poAlign      :: Bool -- ^ fill align the fields
    , poStandard   :: Bool -- ^ old brain dead format
    , poHtml3      :: Bool -- ^ output HTML tables
    , poExpanded   :: Bool -- ^ expand tables
    , poPager      :: Bool -- ^ use pager for output if needed
    , poFieldSep   :: B.ByteString   -- ^ field separator
    , poTableOpt   :: B.ByteString   -- ^ attributes for HTML table element
    , poCaption    :: B.ByteString   -- ^ HTML table caption
    , poFieldName  :: [B.ByteString] -- ^ list of replacement field names
    }


#let alignment t = "%lu", (unsigned long)offsetof(struct {char x__; t (y__); }, y__)
instance Storable PrintOpt where
  sizeOf _ = #{size PQprintOpt}

  alignment _ = #{alignment PQprintOpt}

  peek ptr = do
      a <- fmap pqbool $ #{peek PQprintOpt, header  } ptr
      b <- fmap pqbool $ #{peek PQprintOpt, align   } ptr
      c <- fmap pqbool $ #{peek PQprintOpt, standard} ptr
      d <- fmap pqbool $ #{peek PQprintOpt, html3   } ptr
      e <- fmap pqbool $ #{peek PQprintOpt, expanded} ptr
      f <- fmap pqbool $ #{peek PQprintOpt, pager   } ptr
      g <- B.packCString =<< #{peek PQprintOpt, fieldSep} ptr
      h <- B.packCString =<< #{peek PQprintOpt, tableOpt} ptr
      i <- B.packCString =<< #{peek PQprintOpt, caption} ptr
      j <- #{peek PQprintOpt, fieldName} ptr
      j' <- peekArray0 nullPtr j
      j'' <- mapM B.packCString j'
      return $ PrintOpt a b c d e f g h i j''
      where
        pqbool :: CChar -> Bool
        pqbool = toEnum . fromIntegral

  poke ptr (PrintOpt a b c d e f g h i j) =
      B.useAsCString g $ \g' -> do
        B.useAsCString h $ \h' -> do
          B.useAsCString i $ \i' -> do
            withMany B.useAsCString j $ \j' ->
              withArray0 nullPtr j' $ \j'' -> do
                let a' = (fromIntegral $ fromEnum a)::CChar
                    b' = (fromIntegral $ fromEnum b)::CChar
                    c' = (fromIntegral $ fromEnum c)::CChar
                    d' = (fromIntegral $ fromEnum d)::CChar
                    e' = (fromIntegral $ fromEnum e)::CChar
                    f' = (fromIntegral $ fromEnum f)::CChar
                #{poke PQprintOpt, header}    ptr a'
                #{poke PQprintOpt, align}     ptr b'
                #{poke PQprintOpt, standard}  ptr c'
                #{poke PQprintOpt, html3}     ptr d'
                #{poke PQprintOpt, expanded}  ptr e'
                #{poke PQprintOpt, pager}     ptr f'
                #{poke PQprintOpt, fieldSep}  ptr g'
                #{poke PQprintOpt, tableOpt}  ptr h'
                #{poke PQprintOpt, caption}   ptr i'
                #{poke PQprintOpt, fieldName} ptr j''


-- | Prints out all the rows and, optionally, the column names to the
-- specified output stream.
--
-- This function was formerly used by psql to print query results, but
-- this is no longer the case. Note that it assumes all the data is in
-- text format.
print :: Handle
      -> Result
      -> PrintOpt
      -> IO ()
print h (Result res) po =
    withForeignPtr res $ \resPtr -> do
      B.useAsCString "w" $ \mode -> do
        with po $ \poPtr -> do
          dup_h <- hDuplicate h
          fd <- handleToFd dup_h
          threadWaitWrite fd
          cfile <- c_fdopen (fromIntegral fd) mode
          c_PQprint cfile resPtr poPtr


-- | Returns the error message most recently generated by an operation
-- on the connection.
resultErrorMessage :: Result
                   -> IO B.ByteString
resultErrorMessage (Result res) =
    B.packCString =<< withForeignPtr res c_PQresultErrorMessage


type Oid = CUInt

foreign import ccall unsafe "libpq-fe.h PQstatus"
    c_PQstatus :: Ptr PGconn -> CInt

foreign import ccall unsafe "libpq-fe.h PQsocket"
    c_PQsocket :: Ptr PGconn -> IO CInt

foreign import ccall unsafe "libpq-fe.h PQerrorMessage"
    c_PQerrorMessage :: Ptr PGconn -> IO CString

foreign import ccall unsafe "libpq-fe.h PQconnectStart"
    c_PQconnectStart :: CString ->IO (Ptr PGconn)

foreign import ccall unsafe "libpq-fe.h PQconnectPoll"
    c_PQconnectPoll :: Ptr PGconn ->IO CInt

foreign import ccall unsafe "libpq-fe.h PQresetStart"
    c_PQresetStart :: Ptr PGconn ->IO CInt

foreign import ccall unsafe "libpq-fe.h PQresetPoll"
    c_PQresetPoll :: Ptr PGconn ->IO CInt

foreign import ccall unsafe "libpq-fe.h &PQfinish"
    p_PQfinish :: FunPtr (Ptr PGconn -> IO ())

foreign import ccall unsafe "libpq-fe.h PQsetClientEncoding"
    c_PQsetClientEncoding :: Ptr PGconn -> CString -> IO CInt

foreign import ccall unsafe "libpq-fe.h PQsendQuery"
    c_PQsendQuery :: Ptr PGconn -> CString ->IO CInt

foreign import ccall unsafe "libpq-fe.h PQsendQueryParams"
    c_PQsendQueryParams :: Ptr PGconn -> CString -> CInt -> Ptr Oid
                        -> Ptr CString -> Ptr CInt -> Ptr CInt -> CInt
                        -> IO CInt

foreign import ccall unsafe "libpq-fe.h PQsendPrepare"
    c_PQsendPrepare :: Ptr PGconn -> CString -> CString -> CInt -> Ptr Oid
                    -> IO CInt

foreign import ccall unsafe "libpq-fe.h PQsendQueryPrepared"
    c_PQsendQueryPrepared :: Ptr PGconn -> CString -> CInt -> Ptr CString
                          -> Ptr CInt -> Ptr CInt -> CInt -> IO CInt

foreign import ccall unsafe "libpq-fe.h PQflush"
    c_PQflush :: Ptr PGconn ->IO CInt

foreign import ccall unsafe "libpq-fe.h PQconsumeInput"
    c_PQconsumeInput :: Ptr PGconn ->IO CInt

foreign import ccall unsafe "libpq-fe.h PQisBusy"
    c_PQisBusy :: Ptr PGconn -> IO CInt

foreign import ccall unsafe "libpq-fe.h PQgetResult"
    c_PQgetResult :: Ptr PGconn ->IO (Ptr PGresult)

foreign import ccall unsafe "libpq-fe.h &PQclear"
    p_PQclear :: FunPtr (Ptr PGresult ->IO ())

foreign import ccall unsafe "libpq-fe.h PQresultStatus"
    c_PQresultStatus :: Ptr PGresult -> CInt

foreign import ccall unsafe "libpq-fe.h PQresultErrorMessage"
    c_PQresultErrorMessage :: Ptr PGresult -> IO CString

foreign import ccall unsafe "libpq-fe.h PQntuples"
    c_PQntuples :: Ptr PGresult -> CInt

foreign import ccall unsafe "libpq-fe.h PQnfields"
    c_PQnfields :: Ptr PGresult -> CInt

foreign import ccall unsafe "libpq-fe.h PQfname"
    c_PQfname :: Ptr PGresult -> CInt -> IO CString

foreign import ccall unsafe "libpq-fe.h PQfnumber"
    c_PQfnumber :: Ptr PGresult -> CString -> IO CInt

foreign import ccall unsafe "libpq-fe.h PQftable"
    c_PQftable :: Ptr PGresult -> CInt -> IO Oid

foreign import ccall unsafe "libpq-fe.h PQftablecol"
    c_PQftablecol :: Ptr PGresult -> CInt -> IO CInt

foreign import ccall unsafe "libpq-fe.h PQfformat"
    c_PQfformat :: Ptr PGresult -> CInt -> IO CInt

foreign import ccall unsafe "libpq-fe.h PQftype"
    c_PQftype :: Ptr PGresult -> CInt -> IO Oid

foreign import ccall unsafe "libpq-fe.h PQfmod"
    c_PQfmod :: Ptr PGresult -> CInt -> IO CInt

foreign import ccall unsafe "libpq-fe.h PQfsize"
    c_PQfsize :: Ptr PGresult -> CInt -> IO CInt

foreign import ccall unsafe "libpq-fe.h PQgetvalue"
    c_PQgetvalue :: Ptr PGresult -> CInt -> CInt -> IO CString

foreign import ccall unsafe "libpq-fe.h PQgetisnull"
    c_PQgetisnull :: Ptr PGresult -> CInt -> CInt -> IO CInt

foreign import ccall unsafe "libpq-fe.h PQgetlength"
    c_PQgetlength :: Ptr PGresult -> CInt -> CInt -> IO CInt

foreign import ccall unsafe "stdio.h fdopen"
    c_fdopen :: CInt -> CString -> IO (Ptr CFile)

foreign import ccall unsafe "libpq-fe.h PQprint"
    c_PQprint :: Ptr CFile -> Ptr PGresult -> Ptr PrintOpt -> IO ()

foreign import ccall unsafe "libpq-fe.h PQescapeStringConn"
    c_PQescapeStringConn :: Ptr PGconn
                         -> Ptr Word8 -- Actually (CString)
                         -> CString
                         -> CSize
                         -> Ptr CInt
                         -> IO CSize

foreign import ccall unsafe "libpq-fe.h PQescapeByteaConn"
    c_PQescapeByteaConn :: Ptr PGconn
                        -> CString -- Actually (Ptr CUChar)
                        -> CSize
                        -> Ptr CSize
                        -> IO (Ptr Word8) -- Actually (IO (Ptr CUChar))

foreign import ccall unsafe "libpq-fe.h &PQfreemem"
    p_PQfreemem :: FunPtr (Ptr a -> IO ())
