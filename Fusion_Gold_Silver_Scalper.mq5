//+------------------------------------------------------------------+
//| Gold/Silver Fusion Scalper                                       |
//| Original MQL5 EA inspired by publicly documented trading ideas:  |
//| FVG/OB scoring, momentum, multi-TF trend filters, risk controls,  |
//| and high-water trailing protection.                              |
//|                                                                  |
//| IMPORTANT: This is NOT a copied combination of other EAs.        |
//| It is a new implementation of compatible concepts.              |
//| Test on demo/Strategy Tester before live use.                    |
//+------------------------------------------------------------------+
#property strict
#property version   "1.10"
#property description "Multi-position XAUUSD/XAGUSD M5 scalper with portfolio-risk and daily-DD locks."

#include <Trade/Trade.mqh>
CTrade trade;

//--------------------------- Inputs ---------------------------------
input group "=== Symbols / General ==="
input bool   AllowGold             = true;
input bool   AllowSilver           = true;
input ulong  MagicNumber           = 6102026;
input ENUM_TIMEFRAMES SignalTF     = PERIOD_M5;
input ENUM_TIMEFRAMES SetupTF      = PERIOD_M15;
input ENUM_TIMEFRAMES BiasTF       = PERIOD_H1;

input group "=== London Session ==="
input bool   UseSessionFilter      = true;
input int    LondonStartHour       = 7;     // broker/server hour
input int    LondonEndHour         = 12;    // broker/server hour
input int    SessionMinute         = 0;

input group "=== Trend / Momentum ==="
input int    FastEMA               = 9;
input int    SlowEMA               = 21;
input int    BiasEMA50             = 50;
input int    BiasEMA200            = 200;
input int    RSIPeriod             = 14;
input double RSI_LongMin            = 52.0;
input double RSI_ShortMax           = 48.0;
input int    ADXPeriod              = 14;
input double MinADX                = 18.0;
input int    ATRPeriod              = 14;
input double MinATRPoints          = 80.0;

input group "=== FVG / Order Block Scanner ==="
input int    FVGLookbackBars       = 30;
input double MinFVG_ATR            = 0.15;
input double DisplacementATR       = 1.00;
input int    OBLookbackBars        = 30;
input double OBImpulseATR          = 1.25;
input bool   RequireOBConfluence   = false;
input double MinSetupScore         = 70.0;

input group "=== Entry / Reward ==="
input double MinRR                 = 1.80;
input double StopATRMult           = 1.20;
input double TakeATRMult           = 2.40;
input double EntryBufferATR        = 0.05;
input bool   UseFVGEntry           = true;

input group "=== Risk ==="
input double RiskPercent           = 0.50;
input double MaxDailyLossPercent   = 3.0;
input int    MaxTradesPerDay       = 8;      // Daily entries across EA instances sharing this account/magic
input int    MaxConsecutiveLosses  = 3;
input int    MaxOpenPositions      = 5;      // Per symbol
input int    MaxTotalOpenPositions = 8;      // Across XAUUSD + XAGUSD for this EA magic
input double MaxPortfolioRiskPct  = 2.0;    // Combined open SL risk as % of balance
input bool   BlockAfterLossStreak  = true;
input bool   CloseEAOnDailyDD      = true;   // Close this EA's positions when daily equity DD is hit

input group "=== Spread / Execution ==="
input double MaxSpreadPointsGold   = 80.0;
input double MaxSpreadPointsSilver = 100.0;
input int    MaxSlippagePoints     = 30;

input group "=== Trailing Stop ==="
input bool   UseTrailing           = true;
input double TrailStartATR         = 1.00;
input double TrailATRMult          = 1.00;
input double BreakEvenATR          = 0.75;
input double BreakEvenOffsetATR    = 0.05;
input double HighWaterGivebackPct  = 0.30; // never give back more than 30% of max profit distance
input int    TrailUpdateSeconds    = 2;

input group "=== Safety ==="
input bool   AvoidFridayLate       = true;
input int    FridayStopHour        = 18;
input bool   AvoidLargeSpreadSpike  = true;

//------------------------ Indicator handles -------------------------
int hFast=INVALID_HANDLE, hSlow=INVALID_HANDLE;
int hBias50=INVALID_HANDLE, hBias200=INVALID_HANDLE;
int hRSI=INVALID_HANDLE, hATR=INVALID_HANDLE, hADX=INVALID_HANDLE;

datetime g_lastBar=0;
datetime g_lastTrail=0;
double   g_dayStartEquity=0.0;
int      g_tradesToday=0;
int      g_lossesToday=0;

// Daily equity baseline is shared across charts through terminal global variables.
string g_dayKey="";
string g_tradeCountKey="";
string g_lossCountKey="";

//------------------------ Utility -----------------------------------
bool IsGold()
{
   string s=_Symbol;
   return (StringFind(s,"XAU")>=0 || StringFind(s,"GOLD")>=0);
}
bool IsSilver()
{
   string s=_Symbol;
   return (StringFind(s,"XAG")>=0 || StringFind(s,"SILVER")>=0);
}
bool SymbolAllowed()
{
   if(IsGold() && AllowGold) return true;
   if(IsSilver() && AllowSilver) return true;
   return false;
}
double PointValue(){ return SymbolInfoDouble(_Symbol,SYMBOL_POINT); }
int DigitsValue(){ return (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS); }

double SpreadPoints()
{
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   return (ask-bid)/PointValue();
}
double MaxSpread()
{
   return IsSilver()?MaxSpreadPointsSilver:MaxSpreadPointsGold;
}
bool IsNewBar()
{
   datetime t=iTime(_Symbol,SignalTF,0);
   if(t==0) return false;
   if(t!=g_lastBar){ g_lastBar=t; return true; }
   return false;
}
bool InLondon()
{
   if(!UseSessionFilter) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   int mins=dt.hour*60+dt.min;
   int a=LondonStartHour*60+SessionMinute;
   int b=LondonEndHour*60+SessionMinute;
   return mins>=a && mins<b;
}
bool FridayLate()
{
   if(!AvoidFridayLate) return false;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   return (dt.day_of_week==5 && dt.hour>=FridayStopHour);
}
string DateStamp()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   return StringFormat("%04d%02d%02d",dt.year,dt.mon,dt.day);
}
string AccountPrefix()
{
   return StringFormat("FUSION_%I64d_%I64u_",AccountInfoInteger(ACCOUNT_LOGIN),MagicNumber);
}
void ResetDayIfNeeded()
{
   string stamp=DateStamp();
   string accountPrefix=StringFormat("FUSION_%I64d_",AccountInfoInteger(ACCOUNT_LOGIN));
   g_dayKey=accountPrefix+"EQ_"+stamp;
   g_tradeCountKey=AccountPrefix()+"TR_"+stamp;
   g_lossCountKey=AccountPrefix()+"LS_"+stamp;

   // Shared account-wide baseline prevents each chart/EA restart resetting daily DD.
   if(!GlobalVariableCheck(g_dayKey))
      GlobalVariableSet(g_dayKey,AccountInfoDouble(ACCOUNT_EQUITY));
   g_dayStartEquity=GlobalVariableGet(g_dayKey);

   if(!GlobalVariableCheck(g_tradeCountKey)) GlobalVariableSet(g_tradeCountKey,0.0);
   if(!GlobalVariableCheck(g_lossCountKey)) GlobalVariableSet(g_lossCountKey,0.0);
   g_tradesToday=(int)GlobalVariableGet(g_tradeCountKey);
   g_lossesToday=(int)GlobalVariableGet(g_lossCountKey);
}
bool DailyLossBreached()
{
   if(g_dayKey=="") ResetDayIfNeeded();
   if(g_dayStartEquity<=0) return false;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct=(g_dayStartEquity-eq)/g_dayStartEquity*100.0;
   return lossPct>=MaxDailyLossPercent;
}
bool IsOurPreciousPosition()
{
   string s=PositionGetString(POSITION_SYMBOL);
   bool precious=(StringFind(s,"XAU")>=0 || StringFind(s,"GOLD")>=0 ||
                  StringFind(s,"XAG")>=0 || StringFind(s,"SILVER")>=0);
   return precious && (ulong)PositionGetInteger(POSITION_MAGIC)==MagicNumber;
}
int OpenPositionsForSymbol()
{
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC)==MagicNumber) n++;
   }
   return n;
}
int TotalOurOpenPositions()
{
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(PositionGetTicket(i)==0) continue;
      if(IsOurPreciousPosition()) n++;
   }
   return n;
}
double PositionRiskMoneySelected()
{
   double vol=PositionGetDouble(POSITION_VOLUME);
   double open=PositionGetDouble(POSITION_PRICE_OPEN);
   double sl=PositionGetDouble(POSITION_SL);
   string sym=PositionGetString(POSITION_SYMBOL);
   if(sl<=0 || vol<=0) return DBL_MAX; // no SL means risk cannot be bounded safely
   double tickSize=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE);
   double tickValue=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_VALUE);
   if(tickSize<=0 || tickValue<=0) return DBL_MAX;
   return MathAbs(open-sl)/tickSize*tickValue*vol;
}
double TotalOurOpenRiskMoney()
{
   double total=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(PositionGetTicket(i)==0 || !IsOurPreciousPosition()) continue;
      double risk=PositionRiskMoneySelected();
      if(risk>=DBL_MAX/2) return DBL_MAX;
      total+=risk;
   }
   return total;
}
void CloseOurPositions()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !IsOurPreciousPosition()) continue;
      if(!trade.PositionClose(ticket))
         Print("Daily-DD close failed ticket=",ticket," retcode=",trade.ResultRetcode(),
               " ",trade.ResultRetcodeDescription());
   }
}
void IncrementDailyTradeCount()
{
   if(g_tradeCountKey=="") ResetDayIfNeeded();
   double n=GlobalVariableGet(g_tradeCountKey)+1.0;
   GlobalVariableSet(g_tradeCountKey,n);
   g_tradesToday=(int)n;
}
bool CopyOne(int handle,int buffer,int shift,double &v)
{
   double a[1];
   if(CopyBuffer(handle,buffer,shift,1,a)!=1) return false;
   v=a[0];
   return true;
}
bool CopyRatesTF(ENUM_TIMEFRAMES tf,int start,int count,MqlRates &r[])
{
   ArraySetAsSeries(r,true);
   return CopyRates(_Symbol,tf,start,count,r)==count;
}

//---------------------- Risk / volume -------------------------------
double MoneyPerPriceUnitPerLot()
{
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   if(tickSize<=0 || tickValue<=0) return 0;
   return tickValue/tickSize;
}
double NormalizeVolume(double lots)
{
   double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0 || vmin<=0) return 0;
   if(lots<vmin) return 0; // never round a too-small risk size up to minimum lot
   lots=MathMin(vmax,lots);
   lots=MathFloor(lots/step+1e-9)*step;
   int volDigits=2;
   if(step<0.01) volDigits=3;
   if(step<0.001) volDigits=4;
   return NormalizeDouble(lots,volDigits);
}
double LotsFromRisk(double entry,double sl)
{
   double riskMoney=AccountInfoDouble(ACCOUNT_BALANCE)*RiskPercent/100.0;
   double dist=MathAbs(entry-sl);
   double moneyPerUnit=MoneyPerPriceUnitPerLot();
   if(dist<=0 || moneyPerUnit<=0) return 0;
   double lots=NormalizeVolume(riskMoney/(dist*moneyPerUnit));
   if(lots<=0) return 0;
   // Verify the normalized volume does not exceed the intended cash risk.
   double actualRisk=dist*moneyPerUnit*lots;
   if(actualRisk>riskMoney*1.001) return 0;
   return lots;
}
double MinStopDistance()
{
   long stops=(long)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   return stops*PointValue();
}

//--------------------- Market data ----------------------------------
bool GetCore(double &fast,double &slow,double &b50,double &b200,
             double &rsi,double &atr,double &adx)
{
   if(!CopyOne(hFast,0,1,fast)) return false;
   if(!CopyOne(hSlow,0,1,slow)) return false;
   if(!CopyOne(hBias50,0,1,b50)) return false;
   if(!CopyOne(hBias200,0,1,b200)) return false;
   if(!CopyOne(hRSI,0,1,rsi)) return false;
   if(!CopyOne(hATR,0,1,atr)) return false;
   if(!CopyOne(hADX,0,1,adx)) return false;
   return true;
}

double TickMomentumPoints()
{
   MqlTick ticks[];
   ArraySetAsSeries(ticks,true);
   int n=CopyTicks(_Symbol,ticks,COPY_TICKS_TRADE,0,80);
   if(n<10) return 0;
   double now=ticks[0].last>0?ticks[0].last:ticks[0].bid;
   double old=ticks[n-1].last>0?ticks[n-1].last:ticks[n-1].bid;
   return (now-old)/PointValue();
}

int TrendDirection(double fast,double slow,double b50,double b200,double rsi)
{
   bool bull=(fast>slow && b50>b200 && rsi>=RSI_LongMin);
   bool bear=(fast<slow && b50<b200 && rsi<=RSI_ShortMax);
   if(bull) return 1;
   if(bear) return -1;
   return 0;
}

//--------------------- FVG scanner ----------------------------------
// Returns latest qualifying FVG. FVG definition:
// bullish: low of candle i-2 > high of candle i
// bearish: high of candle i-2 < low of candle i
bool FindFVG(int direction,double atr,double &zoneLow,double &zoneHigh,int &age)
{
   MqlRates r[];
   int need=FVGLookbackBars+5;
   if(!CopyRatesTF(SetupTF,0,need,r)) return false;

   for(int i=2;i<need-1;i++)
   {
      double gap=0;
      if(direction>0)
      {
         zoneLow=r[i].high;
         zoneHigh=r[i-2].low;
         gap=zoneHigh-zoneLow;
         if(gap<=0 || gap<atr*MinFVG_ATR) continue;
      }
      else
      {
         zoneLow=r[i-2].high;
         zoneHigh=r[i].low;
         gap=zoneHigh-zoneLow;
         if(gap<=0 || gap<atr*MinFVG_ATR) continue;
      }
      age=i;
      return true;
   }
   return false;
}

// Simplified order-block proxy: last opposite candle before an impulse.
bool FindOB(int direction,double atr,double &obLow,double &obHigh)
{
   MqlRates r[];
   int need=OBLookbackBars+5;
   if(!CopyRatesTF(SetupTF,0,need,r)) return false;

   for(int i=2;i<need-2;i++)
   {
      double body=MathAbs(r[i-1].close-r[i-1].open);
      if(body<atr*OBImpulseATR) continue;

      if(direction>0 && r[i].close<r[i].open && r[i-1].close>r[i-1].open)
      {
         obLow=r[i].low;
         obHigh=r[i].high;
         return true;
      }
      if(direction<0 && r[i].close>r[i].open && r[i-1].close<r[i-1].open)
      {
         obLow=r[i].low;
         obHigh=r[i].high;
         return true;
      }
   }
   return false;
}
bool ZonesOverlap(double aLow,double aHigh,double bLow,double bHigh)
{
   return MathMax(aLow,bLow)<=MathMin(aHigh,bHigh);
}

double FVGScore(int direction,double atr,double price,double &fvgLow,double &fvgHigh,
                bool &obConfluence)
{
   int age=0;
   if(!FindFVG(direction,atr,fvgLow,fvgHigh,age)) return 0;

   double gap=fvgHigh-fvgLow;
   double gapScore=MathMin(30.0,(gap/atr)*30.0);
   double freshness=MathMax(0.0,10.0-(age*0.5));

   MqlRates r[];
   if(!CopyRatesTF(SetupTF,0,5,r)) return 0;
   double impulseBody=MathAbs(r[1].close-r[1].open);
   double impulseRange=r[1].high-r[1].low;
   double dispScore=0;
   if(impulseRange>0)
      dispScore=MathMin(30.0,(impulseBody/impulseRange)*30.0);

   double b50,b200;
   if(!CopyOne(hBias50,0,1,b50) || !CopyOne(hBias200,0,1,b200)) return 0;
   bool aligned=(direction>0 && b50>b200) || (direction<0 && b50<b200);
   double htfScore=aligned?20.0:0.0;

   double mid=(fvgLow+fvgHigh)/2.0;
   bool pd=(direction>0)?(price<=mid):(price>=mid);
   double pdScore=pd?10.0:0.0;

   double obL=0,obH=0;
   obConfluence=FindOB(direction,atr,obL,obH) &&
                ZonesOverlap(fvgLow,fvgHigh,obL,obH);
   double obBonus=obConfluence?20.0:0.0;

   double total=gapScore+dispScore+htfScore+freshness+pdScore+obBonus;
   if(total>100) total=100;
   return total;
}

//--------------------- Entry scoring --------------------------------
double CalculateScore(int direction,double atr,double fast,double slow,
                      double b50,double b200,double rsi,double adx,
                      double mom,bool &fvgFound,bool &obFound,
                      double &fvgLow,double &fvgHigh)
{
   fvgFound=false; obFound=false;
   double score=0;

   // Trend / HTF confluence
   if(direction>0 && fast>slow) score+=15;
   if(direction<0 && fast<slow) score+=15;
   if(direction>0 && b50>b200) score+=15;
   if(direction<0 && b50<b200) score+=15;

   // RSI momentum
   if(direction>0 && rsi>=55 && rsi<=72) score+=10;
   if(direction<0 && rsi<=45 && rsi>=28) score+=10;

   // ADX
   if(adx>=28) score+=10;
   else if(adx>=MinADX) score+=6;

   // Tick impulse
   double absMom=MathAbs(mom);
   if(absMom>=80) score+=10;
   else if(absMom>=40) score+=6;

   // Volatility
   double atrPts=atr/PointValue();
   if(atrPts>=MinATRPoints) score+=5;

   // FVG quality score contributes up to 25% of its score.
   bool ob=false;
   double rawFVG=FVGScore(direction,atr,
                           SymbolInfoDouble(_Symbol,SYMBOL_BID),
                           fvgLow,fvgHigh,ob);
   if(rawFVG>0)
   {
      fvgFound=true;
      obFound=ob;
      score+=MathMin(25.0,rawFVG*0.25);
   }

   // Require positive tick direction.
   if(direction>0 && mom>0) score+=5;
   if(direction<0 && mom<0) score+=5;

   return MathMin(100.0,score);
}

bool BuildTradeLevels(int direction,double atr,double fvgLow,double fvgHigh,
                      bool fvgFound,double &entry,double &sl,double &tp)
{
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);

   if(direction>0)
   {
      entry=ask;
      if(UseFVGEntry && fvgFound)
      {
         double candidate=fvgLow+atr*EntryBufferATR;
         // Do not place a market trade below current ask.
         if(candidate>ask && candidate<fvgHigh) entry=candidate;
      }
      sl=entry-atr*StopATRMult;
      tp=entry+atr*TakeATRMult;
   }
   else
   {
      entry=bid;
      if(UseFVGEntry && fvgFound)
      {
         double candidate=fvgHigh-atr*EntryBufferATR;
         if(candidate<bid && candidate>fvgLow) entry=candidate;
      }
      sl=entry+atr*StopATRMult;
      tp=entry-atr*TakeATRMult;
   }

   double minDist=MinStopDistance()+2*PointValue();
   if(direction>0)
   {
      if(entry-sl<minDist) sl=entry-minDist;
      if(tp-entry<minDist) tp=entry+minDist;
   }
   else
   {
      if(sl-entry<minDist) sl=entry+minDist;
      if(entry-tp<minDist) tp=entry-minDist;
   }

   double rr=MathAbs(tp-entry)/MathAbs(entry-sl);
   return rr>=MinRR;
}

//--------------------- Position management --------------------------
string HighWaterKey(ulong ticket)
{
   return StringFormat("FUSION_HW_%I64u",ticket);
}
void ManageTrailing()
{
   if(!UseTrailing) return;
   if(TimeCurrent()-g_lastTrail<TrailUpdateSeconds) return;
   g_lastTrail=TimeCurrent();

   double atr;
   if(!CopyOne(hATR,0,0,atr) || atr<=0) return;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double minDist=MinStopDistance()+PointValue();

   // Manage every position on this chart's symbol, not just one tracked ticket.
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;

      long type=PositionGetInteger(POSITION_TYPE);
      bool buy=(type==POSITION_TYPE_BUY);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      double price=buy?bid:ask;
      double profitDist=buy?(price-open):(open-price);
      if(profitDist<=0) continue;

      string key=HighWaterKey(ticket);
      double highWater=GlobalVariableCheck(key)?GlobalVariableGet(key):0.0;
      highWater=MathMax(highWater,profitDist);
      GlobalVariableSet(key,highWater);

      double newSL=sl;
      if(profitDist>=atr*BreakEvenATR)
      {
         double be=buy?open+atr*BreakEvenOffsetATR:open-atr*BreakEvenOffsetATR;
         if(buy) newSL=MathMax(newSL,be);
         else newSL=(newSL==0?be:MathMin(newSL,be));
      }
      if(profitDist>=atr*TrailStartATR)
      {
         double trail=buy?price-atr*TrailATRMult:price+atr*TrailATRMult;
         if(buy) newSL=MathMax(newSL,trail);
         else newSL=(newSL==0?trail:MathMin(newSL,trail));
      }
      double hw=highWater*(1.0-HighWaterGivebackPct);
      if(hw>0)
      {
         double hwSL=buy?open+hw:open-hw;
         if(buy) newSL=MathMax(newSL,hwSL);
         else newSL=(newSL==0?hwSL:MathMin(newSL,hwSL));
      }

      if(buy)
      {
         newSL=MathMin(newSL,bid-minDist);
         if(newSL>0 && (sl==0 || newSL>sl+PointValue()))
            if(!trade.PositionModify(ticket,NormalizeDouble(newSL,DigitsValue()),tp))
               Print("Trailing modify failed ticket=",ticket," retcode=",trade.ResultRetcode());
      }
      else
      {
         newSL=MathMax(newSL,ask+minDist);
         if(newSL>0 && (sl==0 || newSL<sl-PointValue()))
            if(!trade.PositionModify(ticket,NormalizeDouble(newSL,DigitsValue()),tp))
               Print("Trailing modify failed ticket=",ticket," retcode=",trade.ResultRetcode());
      }
   }
}

//--------------------- Dashboard ------------------------------------
void Dashboard(double score,int direction,double rsi,double adx,double mom,
               bool fvg,bool ob)
{
   string dir=direction>0?"BUY":direction<0?"SELL":"WAIT";
   string s="FUSION GOLD/SILVER SCALPER\n";
   s+="Symbol: "+_Symbol+" | TF: M5\n";
   s+="Session: "+(InLondon()?"LONDON":"CLOSED")+"\n";
   s+="Bias: "+dir+" | Score: "+DoubleToString(score,1)+"/100\n";
   s+="RSI: "+DoubleToString(rsi,1)+" | ADX: "+DoubleToString(adx,1)+"\n";
   s+="Tick momentum: "+DoubleToString(mom,1)+" pts\n";
   s+="FVG: "+(fvg?"YES":"NO")+" | OB: "+(ob?"YES":"NO")+"\n";
   s+="Spread: "+DoubleToString(SpreadPoints(),1)+" pts\n";
   s+="Trades today: "+IntegerToString(g_tradesToday)+"/"+IntegerToString(MaxTradesPerDay)+"\n";
   s+="Open EA positions: "+IntegerToString(TotalOurOpenPositions())+"/"+IntegerToString(MaxTotalOpenPositions)+"\n";
   s+="Daily DD cap: "+DoubleToString(MaxDailyLossPercent,2)+"% | Risk cap: "+DoubleToString(MaxPortfolioRiskPct,2)+"%";
   Comment(s);
}

//--------------------- Init / Deinit --------------------------------
int OnInit()
{
   if(!SymbolAllowed())
   {
      Print("Attach this EA to an XAU/XAG symbol. Current symbol: ",_Symbol);
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   hFast=iMA(_Symbol,SignalTF,FastEMA,0,MODE_EMA,PRICE_CLOSE);
   hSlow=iMA(_Symbol,SignalTF,SlowEMA,0,MODE_EMA,PRICE_CLOSE);
   hBias50=iMA(_Symbol,BiasTF,BiasEMA50,0,MODE_EMA,PRICE_CLOSE);
   hBias200=iMA(_Symbol,BiasTF,BiasEMA200,0,MODE_EMA,PRICE_CLOSE);
   hRSI=iRSI(_Symbol,SignalTF,RSIPeriod,PRICE_CLOSE);
   hATR=iATR(_Symbol,SignalTF,ATRPeriod);
   hADX=iADX(_Symbol,SignalTF,ADXPeriod);

   if(hFast==INVALID_HANDLE || hSlow==INVALID_HANDLE ||
      hBias50==INVALID_HANDLE || hBias200==INVALID_HANDLE ||
      hRSI==INVALID_HANDLE || hATR==INVALID_HANDLE || hADX==INVALID_HANDLE)
   {
      Print("Indicator handle creation failed.");
      return INIT_FAILED;
   }

   ResetDayIfNeeded();
   EventSetTimer(1);
   Print("Fusion Scalper initialized on ",_Symbol);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
   if(hFast!=INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow!=INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hBias50!=INVALID_HANDLE) IndicatorRelease(hBias50);
   if(hBias200!=INVALID_HANDLE) IndicatorRelease(hBias200);
   if(hRSI!=INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR!=INVALID_HANDLE) IndicatorRelease(hATR);
   if(hADX!=INVALID_HANDLE) IndicatorRelease(hADX);
}

void OnTimer()
{
   ManageTrailing();
}

//--------------------- Main -----------------------------------------
void OnTick()
{
   ResetDayIfNeeded();
   ManageTrailing();

   if(DailyLossBreached())
   {
      if(CloseEAOnDailyDD) CloseOurPositions();
      return; // hard lock: no new entries once daily equity drawdown cap is hit
   }
   if(!SymbolAllowed()) return;

   double fast,slow,b50,b200,rsi,atr,adx;
   if(!GetCore(fast,slow,b50,b200,rsi,atr,adx)) return;

   double mom=TickMomentumPoints();

   bool fvg=false,ob=false;
   double fvgL=0,fvgH=0;
   int direction=TrendDirection(fast,slow,b50,b200,rsi);
   double score=0;
   if(direction!=0)
      score=CalculateScore(direction,atr,fast,slow,b50,b200,rsi,adx,mom,
                           fvg,ob,fvgL,fvgH);

   Dashboard(score,direction,rsi,adx,mom,fvg,ob);

   // Only evaluate entries once per M5 bar.
   if(!IsNewBar()) return;

   // Hard gates.
   if(!InLondon()) return;
   if(FridayLate()) return;
   if(DailyLossBreached()) return;
   if(g_tradesToday>=MaxTradesPerDay) return;
   if(BlockAfterLossStreak && g_lossesToday>=MaxConsecutiveLosses) return;
   if(OpenPositionsForSymbol()>=MaxOpenPositions) return;
   if(TotalOurOpenPositions()>=MaxTotalOpenPositions) return;

   double spread=SpreadPoints();
   if(spread>MaxSpread()) return;

   double atrPts=atr/PointValue();
   if(atrPts<MinATRPoints) return;
   if(adx<MinADX) return;
   if(score<MinSetupScore) return;
   if(direction==0) return;

   // Optional spread-spike filter: reject if spread is an obvious fraction
   // of the intended stop distance.
   if(AvoidLargeSpreadSpike)
   {
      double stopPts=atr*StopATRMult/PointValue();
      if(stopPts>0 && spread/stopPts>0.18) return;
   }

   double entry,sl,tp;
   if(!BuildTradeLevels(direction,atr,fvgL,fvgH,fvg,entry,sl,tp)) return;

   // For market execution, use current market prices. The FVG zone is
   // used as a confluence/quality filter; no unsafe future-price order
   // is submitted by this version.
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   entry=direction>0?ask:bid;

   if(direction>0)
   {
      sl=entry-atr*StopATRMult;
      tp=entry+atr*TakeATRMult;
   }
   else
   {
      sl=entry+atr*StopATRMult;
      tp=entry-atr*TakeATRMult;
   }

   double rr=MathAbs(tp-entry)/MathAbs(entry-sl);
   if(rr<MinRR) return;

   double lots=LotsFromRisk(entry,sl);
   if(lots<=0) return;

   // Aggregate worst-case risk to all existing EA positions plus this entry.
   double moneyPerUnit=MoneyPerPriceUnitPerLot();
   double proposedRisk=MathAbs(entry-sl)*moneyPerUnit*lots;
   double maxPortfolioMoney=AccountInfoDouble(ACCOUNT_BALANCE)*MaxPortfolioRiskPct/100.0;
   double existingRisk=TotalOurOpenRiskMoney();
   if(existingRisk>=DBL_MAX/2 || existingRisk+proposedRisk>maxPortfolioMoney)
   {
      Print("Entry blocked: portfolio SL risk cap. Existing=",DoubleToString(existingRisk,2),
            " proposed=",DoubleToString(proposedRisk,2),
            " cap=",DoubleToString(maxPortfolioMoney,2));
      return;
   }

   sl=NormalizeDouble(sl,DigitsValue());
   tp=NormalizeDouble(tp,DigitsValue());

   bool ok=false;
   string comment=StringFormat("FUSION-%s-%0.0f",direction>0?"BUY":"SELL",score);

   if(direction>0)
      ok=trade.Buy(lots,_Symbol,0.0,sl,tp,comment);
   else
      ok=trade.Sell(lots,_Symbol,0.0,sl,tp,comment);

   if(ok)
   {
      IncrementDailyTradeCount();
      Print("ENTRY ",comment,
            " lots=",DoubleToString(lots,2),
            " score=",DoubleToString(score,1),
            " SL=",DoubleToString(sl,DigitsValue()),
            " TP=",DoubleToString(tp,DigitsValue()));
   }
   else
   {
      Print("Order failed. Retcode=",trade.ResultRetcode(),
            " ",trade.ResultRetcodeDescription());
   }
}

// Count losses for this EA after deal closes.
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;

   long entry=(long)HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
   if(entry!=DEAL_ENTRY_OUT) return;

   string sym=HistoryDealGetString(trans.deal,DEAL_SYMBOL);
   long magic=HistoryDealGetInteger(trans.deal,DEAL_MAGIC);
   bool precious=(StringFind(sym,"XAU")>=0 || StringFind(sym,"GOLD")>=0 ||
                  StringFind(sym,"XAG")>=0 || StringFind(sym,"SILVER")>=0);
   if(!precious || (ulong)magic!=MagicNumber) return;

   // Multiple EA instances can receive the same transaction; process each deal once.
   string dealKey=StringFormat("FUSION_DEAL_%I64u",trans.deal);
   if(GlobalVariableCheck(dealKey)) return;
   GlobalVariableSet(dealKey,(double)TimeCurrent());

   double profit=HistoryDealGetDouble(trans.deal,DEAL_PROFIT)
                +HistoryDealGetDouble(trans.deal,DEAL_SWAP)
                +HistoryDealGetDouble(trans.deal,DEAL_COMMISSION);

   if(g_lossCountKey=="") ResetDayIfNeeded();
   double losses=GlobalVariableGet(g_lossCountKey);
   if(profit<0) losses++;
   else if(profit>0) losses=0;
   GlobalVariableSet(g_lossCountKey,losses);
   g_lossesToday=(int)losses;

   string hwKey=HighWaterKey(trans.position);
   if(GlobalVariableCheck(hwKey)) GlobalVariableDel(hwKey);
}
