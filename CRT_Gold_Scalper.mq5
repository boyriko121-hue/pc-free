//+------------------------------------------------------------------+
//|                                             CRT_Gold_Scalper.mq5 |
//| CRT-inspired XAUUSD M5 swing-sweep reversal EA with risk controls |
//| Version 2.00                                                     |
//+------------------------------------------------------------------+
#property strict
#property version   "2.00"
#property description "CRT M5 swing-level sweep/rejection EA with progressive stacking, context-aware risk and trailing stops."

#include <Trade/Trade.mqh>

CTrade trade;

//---------------------------- Inputs --------------------------------
input string InpTradeSymbol              = "";       // Symbol (blank = chart symbol)
input ENUM_TIMEFRAMES InpSignalTF         = PERIOD_M5; // Signal timeframe
input ulong  InpMagicNumber               = 26102101; // EA magic number
input int    InpDeviationPoints           = 30;       // Maximum deviation (points)
input int    InpMaxSpreadPoints           = 100;      // Maximum spread (points); 0 = disabled

input bool   InpUseAutoLot                = true;     // Use risk-based lot sizing
input double InpManualLot                 = 0.01;     // Lot when auto sizing is disabled
input double InpRiskPerEntryPct           = 1.0;      // Planned risk per entry (% equity)
input double InpMaxCombinedRiskPct        = 30.0;     // Maximum combined open SL risk (% equity)
input int    InpMaxPositions               = 5;        // Maximum open positions managed by this EA
input double InpMaxLotsPerPosition         = 10.0;     // Absolute per-position lot cap

input double InpDrawdownLockPct            = 60.0;     // Stop new entries at drawdown from stored starting balance (%)
input double InpStartingBalanceOverride    = 0.0;      // 0 = store first observed balance; otherwise use this baseline

input int    InpSwingLookback              = 10;       // Completed candles used to define recent range high/low
input int    InpSweepBufferPoints          = 2;        // Extra distance beyond recent range high/low to qualify as sweep
input int    InpInitialSLBufferPoints      = 30;       // Buffer beyond current sweep candle extreme for initial SL
input int    InpMinSLPoints                = 50;       // Minimum initial SL distance (points)
input int    InpMaxSLPoints                = 3000;     // Maximum initial SL distance (points); 0 = no cap

input bool   InpUseTrailingStop             = true;     // Enable trailing stop
input int    InpTrailActivationPoints       = 200;      // Start trailing after this profit (points)
input int    InpTrailDistancePoints         = 100;      // Stop distance from current price (points)
input int    InpTrailStepPoints             = 20;       // Minimum SL improvement before modifying (points)

enum ENUM_ADDON_DISTANCE_MODE
  {
   ADDON_FIXED_POINTS = 0,  // Fixed price distance in symbol points
   ADDON_ATR_MULTIPLE = 1   // ATR-based distance
  };
input ENUM_ADDON_DISTANCE_MODE InpAddOnDistanceMode = ADDON_FIXED_POINTS; // Add-on distance mode
input int    InpAddOnFixedDistancePoints    = 300;      // Favourable movement required from latest entry
input int    InpATRPeriod                   = 14;       // ATR period for add-on spacing
input double InpAddOnATRMultiple             = 1.0;      // Favourable movement = ATR x multiple

input int    InpTrendFastEMA                = 50;       // Market context fast EMA
input int    InpTrendSlowEMA                = 200;      // Market context slow EMA
input bool   InpUseCounterTrendRiskScaling  = true;     // Allow reversals both ways but reduce risk against EMA trend
input double InpCounterTrendRiskMultiplier  = 0.5;      // Countertrend risk multiplier (0.5 = half risk)
input bool   InpUseLowVolatilityFilter      = false;    // Optional filter for unusually low ATR
input int    InpATRContextAverageBars       = 50;       // Bars used for average ATR context
input double InpMinATRvsAverageRatio        = 0.65;     // Low volatility if ATR(14) < average ATR x ratio

//---------------------------- State ---------------------------------
string   g_symbol = "";
int      g_atrHandle = INVALID_HANDLE;
int      g_fastEmaHandle = INVALID_HANDLE;
int      g_slowEmaHandle = INVALID_HANDLE;
datetime g_trackingBarTime = 0;
double   g_startingBalance = 0.0;
string   g_startBalanceKey = "";
bool     g_entryLock = false;

// Intrabar sweep tracking. The level and extreme are captured before candle close.
bool     g_sellSweepTracked = false;
bool     g_buySweepTracked = false;
datetime g_sellSweepBarTime = 0;
datetime g_buySweepBarTime = 0;
double   g_sellSweepLevel = 0.0;
double   g_buySweepLevel = 0.0;
double   g_sellSweepExtreme = 0.0;
double   g_buySweepExtreme = 0.0;

// Confirmed setup and progressive entries: every add-on uses the original setup SL.
bool     g_pendingSetup = false;
int      g_pendingDirection = 0;
datetime g_pendingSetupBar = 0;
double   g_pendingSweepExtreme = 0.0;
double   g_pendingSweepLevel = 0.0;
bool     g_setupActive = false;
int      g_setupDirection = 0;
datetime g_setupBar = 0;
double   g_sharedSetupSL = 0.0;
double   g_lastEntryPrice = 0.0;
int      g_marketTrend = 0; // 1 bullish, -1 bearish, 0 neutral/unknown
bool     g_lowVolatility = false;
double   g_currentATR = 0.0;
double   g_averageATR = 0.0;

//----------------------- Utility functions --------------------------
double PointSize()
  {
   double p = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   return (p > 0.0 ? p : _Point);
  }

int SymbolDigitsCount()
  {
   return (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
  }

double NormalizePrice(const double price)
  {
   return NormalizeDouble(price, SymbolDigitsCount());
  }

double NormalizeVolume(const double requested)
  {
   double vmin = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;
   vmax = MathMin(vmax, InpMaxLotsPerPosition);
   double vol = MathMax(vmin, MathMin(vmax, requested));
   vol = MathFloor(vol / step + 1e-8) * step;
   int volDigits = 2;
   if(step >= 1.0) volDigits = 0;
   else if(step >= 0.1) volDigits = 1;
   else if(step >= 0.01) volDigits = 2;
   else if(step >= 0.001) volDigits = 3;
   vol = NormalizeDouble(vol, volDigits);
   if(vol < vmin) return 0.0;
   return vol;
  }

bool GetTick(MqlTick &tick)
  {
   return SymbolInfoTick(g_symbol, tick);
  }

bool SpreadIsAcceptable()
  {
   if(InpMaxSpreadPoints <= 0) return true;
   MqlTick tick;
   if(!GetTick(tick)) return false;
   double spreadPts = (tick.ask - tick.bid) / PointSize();
   return (spreadPts <= InpMaxSpreadPoints);
  }

double GetATR()
  {
   if(g_atrHandle == INVALID_HANDLE) return 0.0;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) != 1) return 0.0;
   return buf[0];
  }

int CountOurPositions(int &direction, double &latestEntryPrice, datetime &latestEntryTime)
  {
   int count = 0;
   direction = 0;
   latestEntryPrice = 0.0;
   latestEntryTime = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      count++;
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      int thisDir = (type == POSITION_TYPE_BUY ? 1 : -1);
      if(direction == 0) direction = thisDir;
      else if(direction != thisDir) direction = 2; // mixed directions

      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      if(opened >= latestEntryTime)
        {
         latestEntryTime = opened;
         latestEntryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        }
     }
   return count;
  }

// Estimate loss from current SL for each open EA position, using broker contract calculations.
double CombinedOpenRiskMoney()
  {
   double totalRisk = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);

      if(sl <= 0.0)
      {
         // A position without an SL is treated as maximum risk, so no further entries should be allowed.
         return DBL_MAX / 4.0;
      }

      double profitAtSL = 0.0;
      ENUM_ORDER_TYPE orderType = (type == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
      if(OrderCalcProfit(orderType, g_symbol, volume, openPrice, sl, profitAtSL))
        {
         if(profitAtSL < 0.0) totalRisk += -profitAtSL;
        }
      else
        {
         // Conservative fallback when broker calculation is unavailable.
         totalRisk += AccountInfoDouble(ACCOUNT_EQUITY);
        }
     }
   return totalRisk;
  }

double RiskMoneyForOrder(const ENUM_ORDER_TYPE orderType, const double volume,
                         const double entryPrice, const double slPrice)
  {
   double p = 0.0;
   if(!OrderCalcProfit(orderType, g_symbol, volume, entryPrice, slPrice, p))
      return DBL_MAX / 4.0;
   return MathMax(0.0, -p);
  }

double CalculateLots(const ENUM_ORDER_TYPE orderType, const double entryPrice, const double slPrice)
  {
   if(!InpUseAutoLot) return NormalizeVolume(InpManualLot);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * MathMax(0.01, InpRiskPerEntryPct) / 100.0;
   int tradeDirection = (orderType == ORDER_TYPE_BUY ? 1 : -1);
   if(InpUseCounterTrendRiskScaling && g_marketTrend != 0 && tradeDirection != g_marketTrend)
      riskMoney *= MathMax(0.0, MathMin(1.0, InpCounterTrendRiskMultiplier));
   double oneLotRisk = RiskMoneyForOrder(orderType, 1.0, entryPrice, slPrice);
   if(oneLotRisk <= 0.0 || oneLotRisk >= DBL_MAX / 8.0) return 0.0;
   return NormalizeVolume(riskMoney / oneLotRisk);
  }

bool DrawdownLockReached()
  {
   if(g_startingBalance <= 0.0) return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double thresholdEquity = g_startingBalance * (1.0 - MathMax(0.0, InpDrawdownLockPct) / 100.0);
   return (equity <= thresholdEquity);
  }

bool RiskBudgetAllows(const ENUM_ORDER_TYPE orderType, const double lots,
                      const double entryPrice, const double slPrice)
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0) return false;

   double currentRisk = CombinedOpenRiskMoney();
   if(currentRisk >= DBL_MAX / 8.0) return false;

   double newRisk = RiskMoneyForOrder(orderType, lots, entryPrice, slPrice);
   if(newRisk >= DBL_MAX / 8.0) return false;

   double allowedRisk = equity * MathMax(0.0, InpMaxCombinedRiskPct) / 100.0;
   return (currentRisk + newRisk <= allowedRisk + 0.01);
  }

bool StopsMeetBrokerRules(const double entryPrice, double &slPrice, const bool isBuy)
  {
   double point = PointSize();
   int stopsLevel = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = MathMax((double)stopsLevel * point, point);

   if(isBuy)
     {
      if(slPrice >= entryPrice - minDistance) slPrice = entryPrice - minDistance;
     }
   else
     {
      if(slPrice <= entryPrice + minDistance) slPrice = entryPrice + minDistance;
     }

   slPrice = NormalizePrice(slPrice);
   double distancePts = MathAbs(entryPrice - slPrice) / point;
   if(distancePts < InpMinSLPoints) return false;
   if(InpMaxSLPoints > 0 && distancePts > InpMaxSLPoints) return false;
   return true;
  }

bool FavourableDistanceReached(const int direction, const double latestEntryPrice)
  {
   if(latestEntryPrice <= 0.0) return false;
   MqlTick tick;
   if(!GetTick(tick)) return false;

   double requiredDistance = 0.0;
   if(InpAddOnDistanceMode == ADDON_FIXED_POINTS)
      requiredDistance = MathMax(0, InpAddOnFixedDistancePoints) * PointSize();
   else
     {
      double atr = GetATR();
      if(atr <= 0.0) return false;
      requiredDistance = atr * MathMax(0.0, InpAddOnATRMultiple);
     }

   if(direction == 1)  return (tick.bid >= latestEntryPrice + requiredDistance);
   if(direction == -1) return (tick.ask <= latestEntryPrice - requiredDistance);
   return false;
  }

bool OpenSignalPosition(const int direction, const double sharedSL)
  {
   MqlTick tick;
   if(!GetTick(tick)) return false;

   double point = PointSize();
   bool isBuy = (direction > 0);
   ENUM_ORDER_TYPE orderType = (isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double entryPrice = (isBuy ? tick.ask : tick.bid);
   double slPrice = NormalizePrice(sharedSL);

   // Every position in this setup uses exactly the same stop price.
   int stopsLevel = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double brokerMinDistance = MathMax((double)stopsLevel * point, point);
   if((isBuy && slPrice >= entryPrice - brokerMinDistance) ||
      (!isBuy && slPrice <= entryPrice + brokerMinDistance))
     {
      Print("CRT EA: Add-on skipped; shared setup SL is no longer on the valid side / too close to market.");
      return false;
     }

   double lots = CalculateLots(orderType, entryPrice, slPrice);
   if(lots <= 0.0)
     {
      Print("CRT EA: Signal skipped; calculated lot is below broker minimum or risk calculation failed.");
      return false;
     }

   int existingDirection = 0;
   double latestEntry = 0.0;
   datetime latestTime = 0;
   int positions = CountOurPositions(existingDirection, latestEntry, latestTime);
   if(positions >= InpMaxPositions)
     {
      Print("CRT EA: Maximum position count reached.");
      return false;
     }
   if(positions > 0 && (existingDirection == 2 || existingDirection != direction))
     {
      Print("CRT EA: Entry blocked because existing positions are not aligned with this setup.");
      return false;
     }
   if(!RiskBudgetAllows(orderType, lots, entryPrice, slPrice))
     {
      Print("CRT EA: Entry blocked by combined open stop-loss risk limit.");
      return false;
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(g_symbol);

   string comment = (isBuy ? "CRT M5 BUY" : "CRT M5 SELL");
   bool sent = (isBuy ? trade.Buy(lots, g_symbol, 0.0, slPrice, 0.0, comment)
                      : trade.Sell(lots, g_symbol, 0.0, slPrice, 0.0, comment));
   if(!sent)
     {
      Print("CRT EA: Order failed. Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      return false;
     }

   double filledPrice = trade.ResultPrice();
   if(filledPrice <= 0.0) filledPrice = entryPrice;
   g_lastEntryPrice = filledPrice;
   Print("CRT EA: ", (isBuy ? "BUY" : "SELL"), " opened. Lots=", DoubleToString(lots, 3),
         " Entry=", DoubleToString(filledPrice, SymbolDigitsCount()),
         " Shared SL=", DoubleToString(slPrice, SymbolDigitsCount()),
         " Market context=", (g_marketTrend > 0 ? "EMA bullish" : (g_marketTrend < 0 ? "EMA bearish" : "EMA neutral")),
         " ATR=", DoubleToString(g_currentATR, SymbolDigitsCount()),
         " AvgATR=", DoubleToString(g_averageATR, SymbolDigitsCount()));
   return true;
  }

void UpdateMarketContext()
  {
   g_marketTrend = 0;
   g_lowVolatility = false;
   g_currentATR = 0.0;
   g_averageATR = 0.0;

   double fast[], slow[], atr[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   ArraySetAsSeries(atr, true);
   if(g_fastEmaHandle != INVALID_HANDLE && g_slowEmaHandle != INVALID_HANDLE &&
      CopyBuffer(g_fastEmaHandle, 0, 1, 1, fast) == 1 &&
      CopyBuffer(g_slowEmaHandle, 0, 1, 1, slow) == 1)
     {
      if(fast[0] > slow[0]) g_marketTrend = 1;
      else if(fast[0] < slow[0]) g_marketTrend = -1;
     }

   int count = MathMax(2, InpATRContextAverageBars);
   if(g_atrHandle != INVALID_HANDLE && CopyBuffer(g_atrHandle, 0, 1, count, atr) >= 2)
     {
      int got = ArraySize(atr);
      double sum = 0.0;
      for(int i = 0; i < got; i++) sum += atr[i];
      if(got > 0) g_averageATR = sum / got;
      g_currentATR = atr[0];
      if(g_averageATR > 0.0)
         g_lowVolatility = (g_currentATR < g_averageATR * MathMax(0.0, InpMinATRvsAverageRatio));
     }
  }

// Track whether the current M5 candle sweeps the highest/lowest level of the prior lookback.
// Only confirm after that candle has fully closed and has the required reversal candle colour.
void TrackAndConfirmSweeps()
  {
   datetime currentBar = iTime(g_symbol, InpSignalTF, 0);
   if(currentBar <= 0) return;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(g_symbol, InpSignalTF, 0, 2, rates) < 2) return;

   if(g_trackingBarTime == 0)
      g_trackingBarTime = currentBar;

   // A new candle has begun, so rates[1] is the candle whose sweep we tracked.
   if(currentBar != g_trackingBarTime)
     {
      MqlRates closed = rates[1];
      if(!g_setupActive && !g_pendingSetup)
        {
         if(g_sellSweepTracked && g_sellSweepBarTime == closed.time &&
            closed.close < g_sellSweepLevel && closed.close < closed.open)
           {
            g_pendingSetup = true;
            g_pendingDirection = -1;
            g_pendingSetupBar = closed.time;
            g_pendingSweepExtreme = g_sellSweepExtreme;
            g_pendingSweepLevel = g_sellSweepLevel;
            Print("CRT EA: Confirmed SELL rejection after swing-high sweep. Waiting for entry conditions.");
           }
         else if(g_buySweepTracked && g_buySweepBarTime == closed.time &&
                 closed.close > g_buySweepLevel && closed.close > closed.open)
           {
            g_pendingSetup = true;
            g_pendingDirection = 1;
            g_pendingSetupBar = closed.time;
            g_pendingSweepExtreme = g_buySweepExtreme;
            g_pendingSweepLevel = g_buySweepLevel;
            Print("CRT EA: Confirmed BUY rejection after swing-low sweep. Waiting for entry conditions.");
           }
        }

      g_sellSweepTracked = false;
      g_buySweepTracked = false;
      g_sellSweepBarTime = 0;
      g_buySweepBarTime = 0;
      g_sellSweepLevel = 0.0;
      g_buySweepLevel = 0.0;
      g_sellSweepExtreme = 0.0;
      g_buySweepExtreme = 0.0;
      g_trackingBarTime = currentBar;
     }

   // Need enough completed candles to establish a recent range.
   int lookback = MathMax(3, InpSwingLookback);
   if(Bars(g_symbol, InpSignalTF) < lookback + 3) return;
   double rangeHigh = -DBL_MAX;
   double rangeLow = DBL_MAX;
   for(int shift = 1; shift <= lookback; shift++)
     {
      double h = iHigh(g_symbol, InpSignalTF, shift);
      double l = iLow(g_symbol, InpSignalTF, shift);
      if(h > rangeHigh) rangeHigh = h;
      if(l < rangeLow) rangeLow = l;
     }

   double point = PointSize();
   double buffer = MathMax(0, InpSweepBufferPoints) * point;
   double activeHigh = rates[0].high;
   double activeLow = rates[0].low;

   if(activeHigh > rangeHigh + buffer)
     {
      if(!g_sellSweepTracked || g_sellSweepBarTime != currentBar)
        {
         g_sellSweepTracked = true;
         g_sellSweepBarTime = currentBar;
         g_sellSweepLevel = rangeHigh;
         g_sellSweepExtreme = activeHigh;
        }
      else
         g_sellSweepExtreme = MathMax(g_sellSweepExtreme, activeHigh);
     }

   if(activeLow < rangeLow - buffer)
     {
      if(!g_buySweepTracked || g_buySweepBarTime != currentBar)
        {
         g_buySweepTracked = true;
         g_buySweepBarTime = currentBar;
         g_buySweepLevel = rangeLow;
         g_buySweepExtreme = activeLow;
        }
      else
         g_buySweepExtreme = MathMin(g_buySweepExtreme, activeLow);
     }
  }

void ProcessSignals()
  {
   if(g_entryLock || DrawdownLockReached()) return;
   if(!SpreadIsAcceptable()) return;
   if(InpUseLowVolatilityFilter && g_lowVolatility) return;

   int direction = 0;
   double latestEntry = 0.0;
   datetime latestTime = 0;
   int positions = CountOurPositions(direction, latestEntry, latestTime);

   // Clear a finished setup only after all its positions have closed.
   if(g_setupActive && positions == 0)
     {
      g_setupActive = false;
      g_setupDirection = 0;
      g_setupBar = 0;
      g_sharedSetupSL = 0.0;
      g_lastEntryPrice = 0.0;
      Print("CRT EA: Previous setup has no open positions; setup cleared.");
     }

   if(!g_setupActive)
     {
      if(!g_pendingSetup || positions > 0) return;

      bool isBuy = (g_pendingDirection > 0);
      double point = PointSize();
      double sl = (isBuy ? g_pendingSweepExtreme - InpInitialSLBufferPoints * point
                         : g_pendingSweepExtreme + InpInitialSLBufferPoints * point);
      MqlTick tick;
      if(!GetTick(tick)) return;
      double entry = (isBuy ? tick.ask : tick.bid);
      if(!StopsMeetBrokerRules(entry, sl, isBuy))
        {
         Print("CRT EA: Confirmed setup skipped; shared SL outside configured min/max distance.");
         g_pendingSetup = false;
         return;
        }

      g_setupDirection = g_pendingDirection;
      g_setupBar = g_pendingSetupBar;
      g_sharedSetupSL = sl;
      if(OpenSignalPosition(g_setupDirection, g_sharedSetupSL))
        {
         g_setupActive = true;
         g_pendingSetup = false;
         Print("CRT EA: Progressive stacking enabled for setup bar ", TimeToString(g_setupBar),
               ". All add-ons will use shared SL ", DoubleToString(g_sharedSetupSL, SymbolDigitsCount()));
        }
      return;
     }

   // Progressive stacking: add another position only after favourable travel from latest fill.
   // It is still the same confirmed sweep setup and every position keeps the original shared SL.
   if(positions >= InpMaxPositions || direction == 2 || direction != g_setupDirection) return;
   if(!FavourableDistanceReached(g_setupDirection, g_lastEntryPrice)) return;
   OpenSignalPosition(g_setupDirection, g_sharedSetupSL);
  }

void ManageTrailingStops()
  {
   if(!InpUseTrailingStop) return;
   MqlTick tick;
   if(!GetTick(tick)) return;
   double point = PointSize();
   int stopsLevel = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double brokerMinDistance = MathMax((double)stopsLevel * point, point);
   int count = 0, direction = 0;
   datetime oldestTime = D'3000.12.31 23:59:59';
   double firstEntry = 0.0, bestExistingSL = 0.0, worstExistingSL = 0.0;
   ulong tickets[];
   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      int thisDirection = (type == POSITION_TYPE_BUY ? 1 : -1);
      if(direction == 0) direction = thisDirection;
      if(direction != thisDirection) return;
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      if(opened < oldestTime) { oldestTime = opened; firstEntry = PositionGetDouble(POSITION_PRICE_OPEN); }
      double sl = PositionGetDouble(POSITION_SL);
      if(count == 0) { bestExistingSL = sl; worstExistingSL = sl; }
      else
        {
         if(sl > bestExistingSL) bestExistingSL = sl;
         if(sl < worstExistingSL) worstExistingSL = sl;
        }
      ArrayResize(tickets, count + 1); tickets[count] = ticket; count++;
     }
   if(count == 0 || firstEntry <= 0.0) return;
   bool isBuy = (direction > 0);
   double currentPrice = (isBuy ? tick.bid : tick.ask);
   double profitPoints = (isBuy ? currentPrice - firstEntry : firstEntry - currentPrice) / point;
   if(profitPoints < InpTrailActivationPoints) return;
   double newSL = 0.0;
   if(isBuy)
     {
      newSL = NormalizePrice(currentPrice - MathMax((double)InpTrailDistancePoints * point, brokerMinDistance));
      if(bestExistingSL > 0.0 && newSL <= bestExistingSL + InpTrailStepPoints * point) return;
      if(newSL >= currentPrice - brokerMinDistance) return;
     }
   else
     {
      newSL = NormalizePrice(currentPrice + MathMax((double)InpTrailDistancePoints * point, brokerMinDistance));
      if(worstExistingSL > 0.0 && newSL >= worstExistingSL - InpTrailStepPoints * point) return;
      if(newSL <= currentPrice + brokerMinDistance) return;
     }
   if(g_setupActive && direction == g_setupDirection) g_sharedSetupSL = newSL;
   for(int j = 0; j < ArraySize(tickets); j++)
     {
      ulong ticket = tickets[j];
      if(!PositionSelectByTicket(ticket)) continue;
      double currentTP = PositionGetDouble(POSITION_TP);
      if(!trade.PositionModify(ticket, newSL, currentTP))
         Print("CRT EA: Shared trailing SL modification failed for ticket ", ticket,
               ". Retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
     }
  }

void UpdateEntryLock()
  {
   if(!g_entryLock && DrawdownLockReached())
     {
      g_entryLock = true;
      Print("CRT EA: DRAWDOWN LOCK ACTIVATED. No new entries will be opened. Existing positions remain managed.");
     }
  }

//---------------------------- Events --------------------------------
int OnInit()
  {
   g_symbol = (InpTradeSymbol == "" ? _Symbol : InpTradeSymbol);
   if(!SymbolSelect(g_symbol, true))
     {
      Print("CRT EA: Unable to select symbol ", g_symbol);
      return INIT_FAILED;
     }

   if(InpMaxPositions < 1 || InpMaxCombinedRiskPct <= 0.0 ||
      InpRiskPerEntryPct <= 0.0 || InpTrailDistancePoints < 1 ||
      InpSwingLookback < 3 || InpTrendFastEMA < 1 || InpTrendSlowEMA < 2)
     {
      Print("CRT EA: Invalid input values. Check risk, position and trailing settings.");
      return INIT_PARAMETERS_INCORRECT;
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(g_symbol);

   g_startBalanceKey = "CRT_GS_START_" + IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN))
                       + "_" + IntegerToString((long)InpMagicNumber);

   if(InpStartingBalanceOverride > 0.0)
      g_startingBalance = InpStartingBalanceOverride;
   else if(GlobalVariableCheck(g_startBalanceKey))
      g_startingBalance = GlobalVariableGet(g_startBalanceKey);
   else
     {
      g_startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      GlobalVariableSet(g_startBalanceKey, g_startingBalance);
     }

   if(g_startingBalance <= 0.0)
     {
      Print("CRT EA: Starting balance is invalid.");
      return INIT_FAILED;
     }

   g_atrHandle = iATR(g_symbol, InpSignalTF, InpATRPeriod);
   g_fastEmaHandle = iMA(g_symbol, InpSignalTF, InpTrendFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_slowEmaHandle = iMA(g_symbol, InpSignalTF, InpTrendSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(g_atrHandle == INVALID_HANDLE || g_fastEmaHandle == INVALID_HANDLE || g_slowEmaHandle == INVALID_HANDLE)
     {
      Print("CRT EA: Failed to create ATR/EMA context indicator handles.");
      return INIT_FAILED;
     }

   g_trackingBarTime = iTime(g_symbol, InpSignalTF, 0);
   g_entryLock = DrawdownLockReached();

   Print("CRT Gold Scalper initialized. Symbol=", g_symbol,
         " TF=", EnumToString(InpSignalTF),
         " Starting balance=", DoubleToString(g_startingBalance, 2),
         " Combined risk cap=", DoubleToString(InpMaxCombinedRiskPct, 1), "%",
         " Drawdown lock=", DoubleToString(InpDrawdownLockPct, 1), "%.");

   if(g_entryLock)
      Print("CRT EA: Drawdown lock is already active. Existing positions will still be managed.");

   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_fastEmaHandle != INVALID_HANDLE) IndicatorRelease(g_fastEmaHandle);
   if(g_slowEmaHandle != INVALID_HANDLE) IndicatorRelease(g_slowEmaHandle);
  }

void OnTick()
  {
   // Existing positions remain managed even after the entry lock activates.
   ManageTrailingStops();
   UpdateEntryLock();
   UpdateMarketContext();
   TrackAndConfirmSweeps();
   ProcessSignals();
  }
//+------------------------------------------------------------------+
