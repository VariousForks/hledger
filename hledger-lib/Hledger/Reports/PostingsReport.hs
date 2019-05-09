{-|

Postings report, used by the register command.

-}

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Hledger.Reports.PostingsReport (
  PostingsReport,
  PostingsReportItem,
  postingsReport,
  mkpostingsReportItem,

  -- * Tests
  tests_PostingsReport
)
where

import Data.List
import Data.Maybe
import Data.Ord (comparing)
-- import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar
import Safe (headMay, lastMay)

import Hledger.Data
import Hledger.Query
import Hledger.Utils 
import Hledger.Reports.ReportOptions


-- | A postings report is a list of postings with a running total, a label
-- for the total field, and a little extra transaction info to help with rendering.
-- This is used eg for the register command.
type PostingsReport = (String               -- label for the running balance column XXX remove
                      ,[PostingsReportItem] -- line items, one per posting
                      )
type PostingsReportItem = (Maybe Day    -- The posting date, if this is the first posting in a
                                        -- transaction or if it's different from the previous
                                        -- posting's date. Or if this a summary posting, the
                                        -- report interval's start date if this is the first
                                        -- summary posting in the interval.
                          ,Maybe Day    -- If this is a summary posting, the report interval's
                                        -- end date if this is the first summary posting in
                                        -- the interval.
                          ,Maybe String -- The posting's transaction's description, if this is the first posting in the transaction.
                          ,Posting      -- The posting, possibly with the account name depth-clipped.
                          ,MixedAmount  -- The running total after this posting, or with --average,
                                        -- the running average posting amount. With --historical,
                                        -- postings before the report start date are included in
                                        -- the running total/average.
                          )

-- | Select postings from the journal and add running balance and other
-- information to make a postings report. Used by eg hledger's register command.
postingsReport :: ReportOpts -> Query -> Journal -> PostingsReport
postingsReport ropts@ReportOpts{..} q j =
  (totallabel, items)
    where
      reportspan = adjustReportDates ropts q j
      whichdate = whichDateFromOpts ropts
      depth = queryDepth q

      -- postings to be included in the report, and similarly-matched postings before the report start date
      (precedingps, reportps) = matchedPostingsBeforeAndDuring ropts q j reportspan

      -- We may be converting amounts to value, according to --value-at.
      -- Currently this is done as follows (keep synced with hledger_options.m4.md):
      --  register -M --value-at
      --   transaction: value each posting at posting date, then summarise ; value -H starting balance at day before report start
      --   period:      value each summary posting at period end           ; value -H starting balance at day before report start
      --   date:        value each summary posting at date                 ; value -H starting balance at date
      --  register --value-at
      --   transaction: value each posting at posting date                 ; value -H starting balance at day before report start
      --   period:      value each posting at report end                   ; value -H starting balance at day before report start
      --   date:        value each posting at date                         ; value -H starting balance at date
      --
      --  In all cases, the running total/average is calculated from the above numbers.
      --  This might not always be what you want; to see the running total valued, try a balance report.
      --
      --  "Day before report start" is a bit arbitrary.

      mvalueat = valueTypeFromOpts ropts
      today = fromMaybe (error' "postingsReport: ReportOpts today_ is unset so could not satisfy --value-at=now") today_

      -- Postings or summary pseudo postings to be displayed.
      displayps =
        let
          multiperiod = interval_ /= NoInterval
        in
          if multiperiod then
            let
              showempty = empty_ || average_
              -- for --value-at=transaction, need to value the postings before summarising them
              maybevaluedreportps
                | mvalueat==Just AtTransaction = [postingValueAtDate j (postingDate p) p | p <- reportps]
                | otherwise                    = reportps
              summaryps = summarisePostingsByInterval interval_ whichdate depth showempty reportspan maybevaluedreportps
            in case mvalueat of
              Just AtPeriod      -> [(postingValueAtDate j periodlastday p    , periodend) | (p,periodend) <- summaryps
                                    ,let periodlastday = maybe
                                           (error' "postingsReport: expected a subperiod end date") -- XXX shouldn't happen
                                           (addDays (-1))
                                           periodend
                                    ]
              Just AtNow         -> [(postingValueAtDate j today p            , periodend) | (p,periodend) <- summaryps]
              Just (AtDate d)    -> [(postingValueAtDate j d p                , periodend) | (p,periodend) <- summaryps]
              _                  -> summaryps
          else
            let reportperiodlastday =
                  fromMaybe (error' "postingsReport: expected a non-empty journal") -- XXX shouldn't happen
                  $ reportPeriodOrJournalLastDay ropts j
            in case mvalueat of
              Nothing            -> [(p                                         , Nothing) | p <- reportps]
              Just AtTransaction -> [(postingValueAtDate j (postingDate p) p    , Nothing) | p <- reportps]
              Just AtPeriod      -> [(postingValueAtDate j reportperiodlastday p, Nothing) | p <- reportps]
              Just AtNow         -> [(postingValueAtDate j today p              , Nothing) | p <- reportps]
              Just (AtDate d)    -> [(postingValueAtDate j d p                  , Nothing) | p <- reportps]

      -- posting report items ready for display
      items = dbg1 "postingsReport items" $ postingsReportItems displayps (nullposting,Nothing) whichdate depth valuedstartbal runningcalc startnum
        where
          historical = balancetype_ == HistoricalBalance
          precedingsum = sumPostings precedingps
          precedingavg | null precedingps = 0
                       | otherwise        = divideMixedAmount (fromIntegral $ length precedingps) precedingsum
          startbal | average_  = if historical then precedingavg else 0
                   | otherwise = if historical then precedingsum else 0
          -- For --value-at: convert the initial running total/average to value.
          -- For --value-at=transaction, we don't bother valuing each
          -- preceding posting at posting date - how useful would that
          -- be ? Just value the initial sum/average at report start date.
          valuedstartbal = case mvalueat of
            Nothing            -> startbal
            Just AtTransaction -> mixedAmountValue prices daybeforereportstart startbal
            Just AtPeriod      -> mixedAmountValue prices daybeforereportstart startbal
            Just AtNow         -> mixedAmountValue prices today       startbal
            Just (AtDate d)    -> mixedAmountValue prices d           startbal
            where
              daybeforereportstart = maybe
                                     (error' "postingsReport: expected a non-empty journal") -- XXX shouldn't happen
                                     (addDays (-1))
                                     $ reportPeriodOrJournalStart ropts j
              -- prices are in parse order - sort into date then parse order,
              -- & reversed for quick lookup of the latest price.
              prices = reverse $ sortOn mpdate $ jmarketprices j

          startnum = if historical then length precedingps + 1 else 1
          runningcalc = registerRunningCalculationFn ropts

-- | Based on the given report options, return a function that does the appropriate
-- running calculation for the register report, ie a running average or running total.
-- This function will take the item number, previous average/total, and new posting amount,
-- and return the new average/total.
registerRunningCalculationFn :: ReportOpts -> (Int -> MixedAmount -> MixedAmount -> MixedAmount)
registerRunningCalculationFn ropts
  | average_ ropts = \i avg amt -> avg + divideMixedAmount (fromIntegral i) (amt - avg)
  | otherwise      = \_ bal amt -> bal + amt

totallabel = "Total"

-- | Adjust report start/end dates to more useful ones based on
-- journal data and report intervals. Ie:
-- 1. If the start date is unspecified, use the earliest date in the journal (if any)
-- 2. If the end date is unspecified, use the latest date in the journal (if any)
-- 3. If a report interval is specified, enlarge the dates to enclose whole intervals
adjustReportDates :: ReportOpts -> Query -> Journal -> DateSpan
adjustReportDates opts q j = reportspan
  where
    -- see also multiBalanceReport
    requestedspan       = dbg1 "requestedspan"       $ queryDateSpan' q                                       -- span specified by -b/-e/-p options and query args
    journalspan         = dbg1 "journalspan"         $ dates `spanUnion` date2s                               -- earliest and latest dates (or date2s) in the journal
      where
        dates  = journalDateSpan False j
        date2s = journalDateSpan True  j
    requestedspanclosed = dbg1 "requestedspanclosed" $ requestedspan `spanDefaultsFrom` journalspan           -- if open-ended, close it using the journal's dates (if any)
    intervalspans       = dbg1 "intervalspans"       $ splitSpan (interval_ opts) requestedspanclosed  -- get the whole intervals enclosing that
    mreportstart        = dbg1 "reportstart"         $ maybe Nothing spanStart $ headMay intervalspans        -- start of the first interval, or open ended
    mreportend          = dbg1 "reportend"           $ maybe Nothing spanEnd   $ lastMay intervalspans        -- end of the last interval, or open ended
    reportspan          = dbg1 "reportspan"          $ DateSpan mreportstart mreportend                       -- the requested span enlarged to whole intervals if possible

-- | Find postings matching a given query, within a given date span,
-- and also any similarly-matched postings before that date span.
-- Date restrictions and depth restrictions in the query are ignored.
-- A helper for the postings report.
matchedPostingsBeforeAndDuring :: ReportOpts -> Query -> Journal -> DateSpan -> ([Posting],[Posting])
matchedPostingsBeforeAndDuring opts q j (DateSpan mstart mend) =
  dbg1 "beforeps, duringps" $ span (beforestartq `matchesPosting`) beforeandduringps
  where
    beforestartq = dbg1 "beforestartq" $ dateqtype $ DateSpan Nothing mstart
    beforeandduringps =
      dbg1 "ps5" $ sortBy (comparing sortdate) $                               -- sort postings by date or date2
      dbg1 "ps4" $ (if invert_ opts then map negatePostingAmount else id) $    -- with --invert, invert amounts
      dbg1 "ps3" $ map (filterPostingAmount symq) $                            -- remove amount parts which the query's cur: terms would exclude
      dbg1 "ps2" $ (if related_ opts then concatMap relatedPostings else id) $ -- with -r, replace each with its sibling postings
      dbg1 "ps1" $ filter (beforeandduringq `matchesPosting`) $                -- filter postings by the query, with no start date or depth limit
                  journalPostings $ journalSelectingAmountFromOpts opts j
      where
        beforeandduringq = dbg1 "beforeandduringq" $ And [depthless $ dateless q, beforeendq]
          where
            depthless  = filterQuery (not . queryIsDepth)
            dateless   = filterQuery (not . queryIsDateOrDate2)
            beforeendq = dateqtype $ DateSpan Nothing mend
        sortdate = if date2_ opts then postingDate2 else postingDate
        symq = dbg1 "symq" $ filterQuery queryIsSym q
    dateqtype
      | queryIsDate2 dateq || (queryIsDate dateq && date2_ opts) = Date2
      | otherwise = Date
      where
        dateq = dbg1 "dateq" $ filterQuery queryIsDateOrDate2 $ dbg1 "q" q  -- XXX confused by multiple date:/date2: ?

-- | Generate postings report line items from a list of postings or (with
-- non-Nothing dates attached) summary postings.
postingsReportItems :: [(Posting,Maybe Day)] -> (Posting,Maybe Day) -> WhichDate -> Int -> MixedAmount -> (Int -> MixedAmount -> MixedAmount -> MixedAmount) -> Int -> [PostingsReportItem]
postingsReportItems [] _ _ _ _ _ _ = []
postingsReportItems ((p,menddate):ps) (pprev,menddateprev) wd d b runningcalcfn itemnum = i:(postingsReportItems ps (p,menddate) wd d b' runningcalcfn (itemnum+1))
    where
      i = mkpostingsReportItem showdate showdesc wd menddate p' b'
      (showdate, showdesc) | isJust menddate = (menddate /= menddateprev,        False)
                           | otherwise       = (isfirstintxn || isdifferentdate, isfirstintxn)
      isfirstintxn = ptransaction p /= ptransaction pprev
      isdifferentdate = case wd of PrimaryDate   -> postingDate p  /= postingDate pprev
                                   SecondaryDate -> postingDate2 p /= postingDate2 pprev
      p' = p{paccount= clipOrEllipsifyAccountName d $ paccount p}
      b' = runningcalcfn itemnum b (pamount p)

-- | Generate one postings report line item, containing the posting,
-- the current running balance, and optionally the posting date and/or
-- the transaction description.
mkpostingsReportItem :: Bool -> Bool -> WhichDate -> Maybe Day -> Posting -> MixedAmount -> PostingsReportItem
mkpostingsReportItem showdate showdesc wd menddate p b =
  (if showdate then Just date else Nothing
  ,menddate
  ,if showdesc then Just desc else Nothing
  ,p
  ,b
  )
  where
    date = case wd of PrimaryDate   -> postingDate p
                      SecondaryDate -> postingDate2 p
    desc = T.unpack $ maybe "" tdescription $ ptransaction p

-- | Convert a list of postings into summary postings, one per interval,
-- aggregated to the specified depth if any.
-- Each summary posting will have a non-Nothing interval end date.
summarisePostingsByInterval :: Interval -> WhichDate -> Int -> Bool -> DateSpan -> [Posting] -> [SummaryPosting]
summarisePostingsByInterval interval wd depth showempty reportspan ps = concatMap summarisespan $ splitSpan interval reportspan
    where
      summarisespan s = summarisePostingsInDateSpan s wd depth showempty (postingsinspan s)
      postingsinspan s = filter (isPostingInDateSpan' wd s) ps

-- | A summary posting summarises the activity in one account within a report
-- interval. It is currently kludgily represented by a regular Posting with no
-- description, the interval's start date stored as the posting date, and the
-- interval's end date attached with a tuple.
type SummaryPosting = (Posting, Maybe Day)

-- | Given a date span (representing a report interval) and a list of
-- postings within it, aggregate the postings into one summary posting per
-- account. Each summary posting will have a non-Nothing interval end date.
--
-- When a depth argument is present, postings to accounts of greater
-- depth are also aggregated where possible. If the depth is 0, all
-- postings in the span are aggregated into a single posting with
-- account name "...".
--
-- The showempty flag includes spans with no postings and also postings
-- with 0 amount.
--
summarisePostingsInDateSpan :: DateSpan -> WhichDate -> Int -> Bool -> [Posting] -> [SummaryPosting]
summarisePostingsInDateSpan (DateSpan b e) wd depth showempty ps
    | null ps && (isNothing b || isNothing e) = []
    | null ps && showempty = [(summaryp, Just e')]
    | otherwise = summarypes
    where
      postingdate = if wd == PrimaryDate then postingDate else postingDate2
      b' = fromMaybe (maybe nulldate postingdate $ headMay ps) b
      e' = fromMaybe (maybe (addDays 1 nulldate) postingdate $ lastMay ps) e
      summaryp = nullposting{pdate=Just b'}
      clippedanames | depth > 0 = nub $ map (clipAccountName depth) anames
                    | otherwise = ["..."]
      summaryps | depth > 0 = [summaryp{paccount=a,pamount=balance a} | a <- clippedanames]
                | otherwise = [summaryp{paccount="...",pamount=sum $ map pamount ps}]
      summarypes = map (, Just e') $ (if showempty then id else filter (not . isZeroMixedAmount . pamount)) summaryps
      anames = sort $ nub $ map paccount ps
      -- aggregate balances by account, like ledgerFromJournal, then do depth-clipping
      accts = accountsFromPostings ps
      balance a = maybe nullmixedamt bal $ lookupAccount a accts
        where
          bal = if isclipped a then aibalance else aebalance
          isclipped a = accountNameLevel a >= depth

negatePostingAmount :: Posting -> Posting
negatePostingAmount p = p { pamount = negate $ pamount p }


-- tests

tests_PostingsReport = tests "PostingsReport" [

   tests "postingsReport" $
    let (query, journal) `gives` n = (length $ snd $ postingsReport defreportopts query journal) `is` n
    in [
     -- with the query specified explicitly
      (Any, nulljournal) `gives` 0
     ,(Any, samplejournal) `gives` 13
     -- register --depth just clips account names
     ,(Depth 2, samplejournal) `gives` 13
     ,(And [Depth 1, StatusQ Cleared, Acct "expenses"], samplejournal) `gives` 2
     ,(And [And [Depth 1, StatusQ Cleared], Acct "expenses"], samplejournal) `gives` 2
  
     -- with query and/or command-line options
     ,(length $ snd $ postingsReport defreportopts Any samplejournal) `is` 13
     ,(length $ snd $ postingsReport defreportopts{interval_=Months 1} Any samplejournal) `is` 11
     ,(length $ snd $ postingsReport defreportopts{interval_=Months 1, empty_=True} Any samplejournal) `is` 20
     ,(length $ snd $ postingsReport defreportopts (Acct "assets:bank:checking") samplejournal) `is` 5
  
     -- (defreportopts, And [Acct "a a", Acct "'b"], samplejournal2) `gives` 0
     -- [(Just (parsedate "2008-01-01","income"),assets:bank:checking             $1,$1)
     -- ,(Nothing,income:salary                   $-1,0)
     -- ,(Just (2008-06-01,"gift"),assets:bank:checking             $1,$1)
     -- ,(Nothing,income:gifts                    $-1,0)
     -- ,(Just (2008-06-02,"save"),assets:bank:saving               $1,$1)
     -- ,(Nothing,assets:bank:checking            $-1,0)
     -- ,(Just (2008-06-03,"eat & shop"),expenses:food                    $1,$1)
     -- ,(Nothing,expenses:supplies                $1,$2)
     -- ,(Nothing,assets:cash                     $-2,0)
     -- ,(Just (2008-12-31,"pay off"),liabilities:debts                $1,$1)
     -- ,(Nothing,assets:bank:checking            $-1,0)    

    {-
        let opts = defreportopts
        (postingsReportAsText opts $ postingsReport opts (queryFromOpts date1 opts) j) `is` unlines
         ["2008/01/01 income               assets:bank:checking             $1           $1"
         ,"                                income:salary                   $-1            0"
         ,"2008/06/01 gift                 assets:bank:checking             $1           $1"
         ,"                                income:gifts                    $-1            0"
         ,"2008/06/02 save                 assets:bank:saving               $1           $1"
         ,"                                assets:bank:checking            $-1            0"
         ,"2008/06/03 eat & shop           expenses:food                    $1           $1"
         ,"                                expenses:supplies                $1           $2"
         ,"                                assets:cash                     $-2            0"
         ,"2008/12/31 pay off              liabilities:debts                $1           $1"
         ,"                                assets:bank:checking            $-1            0"
         ]
    
      ,"postings report with cleared option" ~:
       do
        let opts = defreportopts{cleared_=True}
        j <- readJournal' sample_journal_str
        (postingsReportAsText opts $ postingsReport opts (queryFromOpts date1 opts) j) `is` unlines
         ["2008/06/03 eat & shop           expenses:food                    $1           $1"
         ,"                                expenses:supplies                $1           $2"
         ,"                                assets:cash                     $-2            0"
         ,"2008/12/31 pay off              liabilities:debts                $1           $1"
         ,"                                assets:bank:checking            $-1            0"
         ]
    
      ,"postings report with uncleared option" ~:
       do
        let opts = defreportopts{uncleared_=True}
        j <- readJournal' sample_journal_str
        (postingsReportAsText opts $ postingsReport opts (queryFromOpts date1 opts) j) `is` unlines
         ["2008/01/01 income               assets:bank:checking             $1           $1"
         ,"                                income:salary                   $-1            0"
         ,"2008/06/01 gift                 assets:bank:checking             $1           $1"
         ,"                                income:gifts                    $-1            0"
         ,"2008/06/02 save                 assets:bank:saving               $1           $1"
         ,"                                assets:bank:checking            $-1            0"
         ]
    
      ,"postings report sorts by date" ~:
       do
        j <- readJournal' $ unlines
            ["2008/02/02 a"
            ,"  b  1"
            ,"  c"
            ,""
            ,"2008/01/01 d"
            ,"  e  1"
            ,"  f"
            ]
        let opts = defreportopts
        registerdates (postingsReportAsText opts $ postingsReport opts (queryFromOpts date1 opts) j) `is` ["2008/01/01","2008/02/02"]
    
      ,"postings report with account pattern" ~:
       do
        j <- samplejournal
        let opts = defreportopts{patterns_=["cash"]}
        (postingsReportAsText opts $ postingsReport opts (queryFromOpts date1 opts) j) `is` unlines
         ["2008/06/03 eat & shop           assets:cash                     $-2          $-2"
         ]
    
      ,"postings report with account pattern, case insensitive" ~:
       do
        j <- samplejournal
        let opts = defreportopts{patterns_=["cAsH"]}
        (postingsReportAsText opts $ postingsReport opts (queryFromOpts date1 opts) j) `is` unlines
         ["2008/06/03 eat & shop           assets:cash                     $-2          $-2"
         ]
    
      ,"postings report with display expression" ~:
       do
        j <- samplejournal
        let gives displayexpr =
                (registerdates (postingsReportAsText opts $ postingsReport opts (queryFromOpts date1 opts) j) `is`)
                    where opts = defreportopts{display_=Just displayexpr}
        "d<[2008/6/2]"  `gives` ["2008/01/01","2008/06/01"]
        "d<=[2008/6/2]" `gives` ["2008/01/01","2008/06/01","2008/06/02"]
        "d=[2008/6/2]"  `gives` ["2008/06/02"]
        "d>=[2008/6/2]" `gives` ["2008/06/02","2008/06/03","2008/12/31"]
        "d>[2008/6/2]"  `gives` ["2008/06/03","2008/12/31"]
    
      ,"postings report with period expression" ~:
       do
        j <- samplejournal
        let periodexpr `gives` dates = do
              j' <- samplejournal
              registerdates (postingsReportAsText opts $ postingsReport opts (queryFromOpts date1 opts) j') `is` dates
                  where opts = defreportopts{period_=maybePeriod date1 periodexpr}
        ""     `gives` ["2008/01/01","2008/06/01","2008/06/02","2008/06/03","2008/12/31"]
        "2008" `gives` ["2008/01/01","2008/06/01","2008/06/02","2008/06/03","2008/12/31"]
        "2007" `gives` []
        "june" `gives` ["2008/06/01","2008/06/02","2008/06/03"]
        "monthly" `gives` ["2008/01/01","2008/06/01","2008/12/01"]
        "quarterly" `gives` ["2008/01/01","2008/04/01","2008/10/01"]
        let opts = defreportopts{period_=maybePeriod date1 "yearly"}
        (postingsReportAsText opts $ postingsReport opts (queryFromOpts date1 opts) j) `is` unlines
         ["2008/01/01 - 2008/12/31         assets:bank:saving               $1           $1"
         ,"                                assets:cash                     $-2          $-1"
         ,"                                expenses:food                    $1            0"
         ,"                                expenses:supplies                $1           $1"
         ,"                                income:gifts                    $-1            0"
         ,"                                income:salary                   $-1          $-1"
         ,"                                liabilities:debts                $1            0"
         ]
        let opts = defreportopts{period_=maybePeriod date1 "quarterly"}
        registerdates (postingsReportAsText opts $ postingsReport opts (queryFromOpts date1 opts) j) `is` ["2008/01/01","2008/04/01","2008/10/01"]
        let opts = defreportopts{period_=maybePeriod date1 "quarterly",empty_=True}
        registerdates (postingsReportAsText opts $ postingsReport opts (queryFromOpts date1 opts) j) `is` ["2008/01/01","2008/04/01","2008/07/01","2008/10/01"]
    
      ]
    
      , "postings report with depth arg" ~:
       do
        j <- samplejournal
        let opts = defreportopts{depth_=Just 2}
        (postingsReportAsText opts $ postingsReport opts (queryFromOpts date1 opts) j) `is` unlines
         ["2008/01/01 income               assets:bank                      $1           $1"
         ,"                                income:salary                   $-1            0"
         ,"2008/06/01 gift                 assets:bank                      $1           $1"
         ,"                                income:gifts                    $-1            0"
         ,"2008/06/02 save                 assets:bank                      $1           $1"
         ,"                                assets:bank                     $-1            0"
         ,"2008/06/03 eat & shop           expenses:food                    $1           $1"
         ,"                                expenses:supplies                $1           $2"
         ,"                                assets:cash                     $-2            0"
         ,"2008/12/31 pay off              liabilities:debts                $1           $1"
         ,"                                assets:bank                     $-1            0"
         ]
    
    -}
    ]

  ,tests "summarisePostingsByInterval" [
    tests "summarisePostingsByInterval" [
      summarisePostingsByInterval (Quarters 1) PrimaryDate 99999 False (DateSpan Nothing Nothing) [] `is` []
      ]
   ]
  
  -- ,tests_summarisePostingsInDateSpan = [
    --  "summarisePostingsInDateSpan" ~: do
    --   let gives (b,e,depth,showempty,ps) =
    --           (summarisePostingsInDateSpan (mkdatespan b e) depth showempty ps `is`)
    --   let ps =
    --           [
    --            nullposting{lpdescription="desc",lpaccount="expenses:food:groceries",lpamount=Mixed [usd 1]}
    --           ,nullposting{lpdescription="desc",lpaccount="expenses:food:dining",   lpamount=Mixed [usd 2]}
    --           ,nullposting{lpdescription="desc",lpaccount="expenses:food",          lpamount=Mixed [usd 4]}
    --           ,nullposting{lpdescription="desc",lpaccount="expenses:food:dining",   lpamount=Mixed [usd 8]}
    --           ]
    --   ("2008/01/01","2009/01/01",0,9999,False,[]) `gives`
    --    []
    --   ("2008/01/01","2009/01/01",0,9999,True,[]) `gives`
    --    [
    --     nullposting{lpdate=parsedate "2008/01/01",lpdescription="- 2008/12/31"}
    --    ]
    --   ("2008/01/01","2009/01/01",0,9999,False,ts) `gives`
    --    [
    --     nullposting{lpdate=parsedate "2008/01/01",lpdescription="- 2008/12/31",lpaccount="expenses:food",          lpamount=Mixed [usd 4]}
    --    ,nullposting{lpdate=parsedate "2008/01/01",lpdescription="- 2008/12/31",lpaccount="expenses:food:dining",   lpamount=Mixed [usd 10]}
    --    ,nullposting{lpdate=parsedate "2008/01/01",lpdescription="- 2008/12/31",lpaccount="expenses:food:groceries",lpamount=Mixed [usd 1]}
    --    ]
    --   ("2008/01/01","2009/01/01",0,2,False,ts) `gives`
    --    [
    --     nullposting{lpdate=parsedate "2008/01/01",lpdescription="- 2008/12/31",lpaccount="expenses:food",lpamount=Mixed [usd 15]}
    --    ]
    --   ("2008/01/01","2009/01/01",0,1,False,ts) `gives`
    --    [
    --     nullposting{lpdate=parsedate "2008/01/01",lpdescription="- 2008/12/31",lpaccount="expenses",lpamount=Mixed [usd 15]}
    --    ]
    --   ("2008/01/01","2009/01/01",0,0,False,ts) `gives`
    --    [
    --     nullposting{lpdate=parsedate "2008/01/01",lpdescription="- 2008/12/31",lpaccount="",lpamount=Mixed [usd 15]}
    --    ]
  
 ]
