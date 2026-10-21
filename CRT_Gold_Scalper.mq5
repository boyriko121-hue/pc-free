//+------------------------------------------------------------------+
//|                                             CRT_Gold_Scalper.mq5 |
//| CRT-inspired XAUUSD M1 sweep/rejection scalper with risk controls |
//| Version 1.00                                                     |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "CRT-inspired Gold M1 sweep/rejection EA with pyramiding, risk-based sizing and trailing stops."

#include <Trade/Trade.mqh>

CTrade trade;

//---------------------------- Inputs --------------------------------
input string InpTradeSymbol              = "";       // Symbol (blank = chart symbol)
input ENUM_TIMEFRAMES InpSignalTF         = PERIOD_M1; // Signal timeframe
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

input int    InpSweepBufferPoints          = 2;        // Extra distance beyond previous candle high/low to qualify as sweep
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

//---------------------------- State ---------------------------------
string   g_symbol = "";
int      g_atrHandle = INVALID_HANDLE;
datetime g_lastBarTime = 0;
datetime g_lastUsedSellSweepBar = 0;
datetime g_lastUsedBuySweepBar = 0;
double   g_startingBalance = 0.0;
string   g_startBalanceKey = "";
bool     g_entryLock = false;

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

bool IsNewBar()
  {
   datetime t = iTime(g_symbol, InpSignalTF, 0);
   if(t <= 0) return false;
   if(t != g_lastBarTime)
     {
      g_lastBarTime = t;
      return true;
     }
   return false;
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

bool FindSweepSignal(int &signal, datetime &signalBar, double &sweepExtreme)
  {
   signal = 0;
   signalBar = iTime(g_symbol, InpSignalTF, 0);
   sweepExtreme = 0.0;
   if(signalBar <= 0) return false;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(g_symbol, InpSignalTF, 0, 3, rates) < 3) return false;

   // rates[1] is the last completed candle; rates[0] is the active sweep candle.
   double prevOpen = rates[1].open;
   double prevClose = rates[1].close;
   double prevHigh = rates[1].high;
   double prevLow = rates[1].low;
   double activeHigh = rates[0].high;
   double activeLow = rates[0].low;

   MqlTick tick;
   if(!GetTick(tick)) return false;

   double point = PointSize();
   double sweepBuffer = InpSweepBufferPoints * point;

   // Previous candle bullish: sweep its high, then price returns below that high -> SELL.
   if(prevClose > prevOpen &&
      activeHigh > prevHigh + sweepBuffer &&
      tick.bid < prevHigh &&
      g_lastUsedSellSweepBar != signalBar)
     {
      signal = -1;
      sweepExtreme = activeHigh;
      return true;
     }

   // Previous candle bearish: sweep its low, then price returns above that low -> BUY.
   if(prevClose < prevOpen &&
      activeLow < prevLow - sweepBuffer &&
      tick.ask > prevLow &&
      g_lastUsedBuySweepBar != signalBar)
     {
      signal = 1;
      sweepExtreme = activeLow;
      return true;
     }

   return false;
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

bool OpenSignalPosition(const int direction, const double sweepExtreme)
  {
   MqlTick tick;
   if(!GetTick(tick)) return false;

   double point = PointSize();
   bool isBuy = (direction > 0);
   ENUM_ORDER_TYPE orderType = (isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double entryPrice = (isBuy ? tick.ask : tick.bid);

   double slPrice = 0.0;
   if(isBuy)
      slPrice = sweepExtreme - InpInitialSLBufferPoints * point;
   else
      slPrice = sweepExtreme + InpInitialSLBufferPoints * point;

   if(!StopsMeetBrokerRules(entryPrice, slPrice, isBuy))
     {
      Print("CRT EA: Signal skipped; initial SL distance is outside configured limits. Distance points=",
            DoubleToString(MathAbs(entryPrice - slPrice) / point, 1));
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

   if(!RiskBudgetAllows(orderType, lots, entryPrice, slPrice))
     {
      Print("CRT EA: Entry blocked by combined open stop-loss risk limit.");
      return false;
     }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(g_symbol);

   string comment = (isBuy ? "CRT Sweep BUY" : "CRT Sweep SELL");
   bool sent = false;
   if(isBuy)
      sent = trade.Buy(lots, g_symbol, 0.0, slPrice, 0.0, comment);
   else
      sent = trade.Sell(lots, g_symbol, 0.0, slPrice, 0.0, comment);

   if(!sent)
     {
      Print("CRT EA: Order failed. Retcode=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription());
      return false;
     }

   Print("CRT EA: ", (isBuy ? "BUY" : "SELL"), " opened. Lots=",
         DoubleToString(lots, 3), " SL=", DoubleToString(slPrice, SymbolDigitsCount()));

   return true;
  }

void ManageTrailingStops()
  {
   if(!InpUseTrailingStop) return;

   MqlTick tick;
   if(!GetTick(tick)) return;

   double point = PointSize();
   int stopsLevel = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double brokerMinDistance = MathMax((double)stopsLevel * point, point);

   for(int i = PositionsTotal() - 1; i >= 0; --i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      bool isBuy = (type == POSITION_TYPE_BUY);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double currentPrice = (isBuy ? tick.bid : tick.ask);
      double profitPoints = (isBuy ? currentPrice - openPrice : openPrice - currentPrice) / point;

      if(profitPoints < InpTrailActivationPoints) continue;

      double newSL = 0.0;
      if(isBuy)
        {
         newSL = currentPrice - MathMax((double)InpTrailDistancePoints * point, brokerMinDistance);
         newSL = NormalizePrice(newSL);
         // Only move a BUY stop upwards; never loosen the stop.
         if(currentSL > 0.0 && newSL <= currentSL + InpTrailStepPoints * point) continue;
         if(newSL >= currentPrice - brokerMinDistance) continue;
        }
      else
        {
         newSL = currentPrice + MathMax((double)InpTrailDistancePoints * point, brokerMinDistance);
         newSL = NormalizePrice(newSL);
         // Only move a SELL stop downwards; never loosen the stop.
         if(currentSL > 0.0 && newSL >= currentSL - InpTrailStepPoints * point) continue;
         if(newSL <= currentPrice + brokerMinDistance) continue;
        }

      if(!trade.PositionModify(ticket, newSL, currentTP))
         Print("CRT EA: Trailing SL modification failed for ticket ", ticket,
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

void ProcessSignals()
  {
   if(g_entryLock || DrawdownLockReached()) return;
   if(!SpreadIsAcceptable()) return;

   int signal = 0;
   datetime signalBar = 0;
   double sweepExtreme = 0.0;
   if(!FindSweepSignal(signal, signalBar, sweepExtreme)) return;

   int existingDirection = 0;
   double latestEntryPrice = 0.0;
   datetime latestEntryTime = 0;
   int positionCount = CountOurPositions(existingDirection, latestEntryPrice, latestEntryTime);

   // One initial position when flat. If positions exist, only pyramid in the same direction,
   // only after favourable movement from the most recent entry and a fresh new sweep signal.
   if(positionCount > 0)
     {
      if(existingDirection == 2 || existingDirection != signal) return;
      if(!FavourableDistanceReached(signal, latestEntryPrice)) return;
     }

   if(OpenSignalPosition(signal, sweepExtreme))
     {
      if(signal < 0) g_lastUsedSellSweepBar = signalBar;
      else           g_lastUsedBuySweepBar = signalBar;
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
      InpRiskPerEntryPct <= 0.0 || InpTrailDistancePoints < 1)
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

   if(InpAddOnDistanceMode == ADDON_ATR_MULTIPLE)
     {
      g_atrHandle = iATR(g_symbol, InpSignalTF, InpATRPeriod);
      if(g_atrHandle == INVALID_HANDLE)
        {
         Print("CRT EA: Failed to create ATR handle.");
         return INIT_FAILED;
        }
     }

   g_lastBarTime = iTime(g_symbol, InpSignalTF, 0);
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
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
  }

void OnTick()
  {
   // Manage risk and existing positions on every tick, even after the entry lock.
   ManageTrailingStops();
   UpdateEntryLock();

   // Signal evaluation is tick-based so the EA can detect the sweep and rejection
   // during the active M1 candle instead of waiting for the candle to close.
   ProcessSignals();
  }
//+------------------------------------------------------------------+
