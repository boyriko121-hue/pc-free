//+------------------------------------------------------------------+
//| Fusion_MachineGun_Recreation.mq5                                 |
//| Video-inspired feature recreation; original implementation.      |
//| Attach to a GOLD chart (broker symbol may be XAUUSD, XAUUSDm, etc.)|
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Video-inspired Gold basket EA: breakout, retest, EMA pullback, layered entries, basket risk controls."

#include <Trade/Trade.mqh>
CTrade trade;

enum ENUM_ENTRY_METHOD
{
   ENTRY_MARKET_ONLY = 0,
   ENTRY_LIMIT_LAYERS_ONLY = 1,
   ENTRY_MARKET_AND_LAYERS = 2
};

enum ENUM_SIGNAL_MODE
{
   SIGNAL_BREAKOUT = 0,
   SIGNAL_RETEST = 1,
   SIGNAL_EMA_PULLBACK = 2,
   SIGNAL_ANY_ENABLED = 3
};

input ENUM_ENTRY_METHOD EntryMethod = ENTRY_MARKET_AND_LAYERS;
input ENUM_SIGNAL_MODE SignalMode = SIGNAL_ANY_ENABLED;
input bool EnableBreakout = true;
input bool EnableRetest = true;
input bool EnableEMAPullback = true;

input ENUM_TIMEFRAMES SignalTF = PERIOD_M5;
input ENUM_TIMEFRAMES TrendTF = PERIOD_H1;
input int FastEMA = 50;
input int SlowEMA = 200;
input int RangeBars = 12;
input int RetestLookbackBars = 8;
input double RetestToleranceATR = 0.20;
input double PullbackToleranceATR = 0.35;
input double MinBodyATR = 0.20;
input int ATRPeriod = 14;

input double BasketRiskPercent = 1.0;        // Intended risk for a new basket
input double MaxTotalOpenRiskPercent = 3.0;  // Approximate EA open risk cap
input double MainTargetR = 2.0;
input double LayerStartR = 0.35;
input double LayerEndR = 0.85;
input int LayerCount = 3;
input double MaxLotPerOrder = 0.50;
input int MaxPositions = 8;
input int MaxSpreadPoints = 80;
input int SlippagePoints = 30;
input double DailyLossLimitPercent = 3.0;
input double MaxEquityDrawdownPercent = 8.0;
input bool UseBreakEven = true;
input double BreakEvenAtR = 1.0;
input bool UseTrailingStop = true;
input double TrailStartR = 1.25;
input double TrailATRMultiplier = 1.2;
input bool UsePartialClose = true;
input double PartialCloseAtR = 1.0;
input double PartialClosePercent = 50.0;
input bool EnableRescueRecycling = false; // Off by default: increases complexity/risk
input bool AllowBuy = true;
input bool AllowSell = true;
input ulong MagicNumber = 26101701;

int hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE, hTrendFast = INVALID_HANDLE, hTrendSlow = INVALID_HANDLE, hATR = INVALID_HANDLE;
datetime lastBarTime = 0;
int dayKey = -1;
double dayStartEquity = 0.0;
double initialEquity = 0.0;

string GVPartial(ulong ticket) { return "FMGR_P_" + (string)ticket; }
string GVInitialRisk(ulong ticket) { return "FMGR_R_" + (string)ticket; }

int MakeDayKey(datetime t)
{
   MqlDateTime d; TimeToStruct(t,d);
   return d.year*10000+d.mon*100+d.day;
}

void UpdateDayBaseline()
{
   int k=MakeDayKey(TimeCurrent());
   if(k!=dayKey)
   {
      dayKey=k;
      dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   }
}

bool DailyLock()
{
   UpdateDayBaseline();
   if(dayStartEquity<=0) return false;
   double loss=(dayStartEquity-AccountInfoDouble(ACCOUNT_EQUITY))/dayStartEquity*100.0;
   return loss>=DailyLossLimitPercent;
}

bool EquityLock()
{
   if(initialEquity<=0) return false;
   double dd=(initialEquity-AccountInfoDouble(ACCOUNT_EQUITY))/initialEquity*100.0;
   return dd>=MaxEquityDrawdownPercent;
}

bool IsNewBar()
{
   datetime t=iTime(_Symbol,SignalTF,0);
   if(t==0 || t==lastBarTime) return false;
   lastBarTime=t; return true;
}

bool ReadValue(int handle,int shift,double &value)
{
   double b[]; ArraySetAsSeries(b,true);
   if(handle==INVALID_HANDLE || CopyBuffer(handle,0,shift,1,b)!=1) return false;
   value=b[0]; return true;
}

bool ReadRates(MqlRates &r[],int count)
{
   ArraySetAsSeries(r,true);
   return CopyRates(_Symbol,SignalTF,0,count,r)==count;
}

double GetATR(int shift=1)
{
   double v=0; if(!ReadValue(hATR,shift,v)) return 0; return v;
}

int TrendDirection()
{
   double f=0,s=0;
   if(!ReadValue(hTrendFast,1,f) || !ReadValue(hTrendSlow,1,s)) return 0;
   if(f>s) return 1; if(f<s) return -1; return 0;
}

double NormalizeVolume(double lots)
{
   double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vmax=MathMin(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),MaxLotPerOrder);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(step<=0) return 0;
   lots=MathMax(vmin,MathMin(vmax,lots));
   lots=MathFloor(lots/step)*step;
   return NormalizeDouble(lots,2);
}

double LotsForRisk(double entry,double sl,double riskMoney)
{
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue<=0) tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   if(tickSize<=0 || tickValue<=0 || MathAbs(entry-sl)<=0) return 0;
   double lossPerLot=MathAbs(entry-sl)/tickSize*tickValue;
   if(lossPerLot<=0) return 0;
   return NormalizeVolume(riskMoney/lossPerLot);
}

double ApproxOpenRiskPercent()
{
   double totalRisk=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol || (ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      double sl=PositionGetDouble(POSITION_SL);
      if(sl<=0) continue;
      double op=PositionGetDouble(POSITION_PRICE_OPEN);
      double vol=PositionGetDouble(POSITION_VOLUME);
      double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
      double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tickValue<=0) tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
      if(tickSize>0 && tickValue>0) totalRisk+=MathAbs(op-sl)/tickSize*tickValue*vol;
   }
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   return eq>0?totalRisk/eq*100.0:100.0;
}

int CountOurPositions()
{
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t && PositionSelectByTicket(t) && PositionGetString(POSITION_SYMBOL)==_Symbol && (ulong)PositionGetInteger(POSITION_MAGIC)==MagicNumber) n++;
   }
   return n;
}

int CountOurOrders()
{
   int n=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);
      if(t && OrderSelect(t) && OrderGetString(ORDER_SYMBOL)==_Symbol && (ulong)OrderGetInteger(ORDER_MAGIC)==MagicNumber) n++;
   }
   return n;
}

bool SpreadOK()
{
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   return ask>0 && bid>0 && (ask-bid)/_Point<=MaxSpreadPoints;
}

bool CandleBullish(MqlRates &r) { return r.close>r.open; }
bool CandleBearish(MqlRates &r) { return r.close<r.open; }

int SignalBreakout()
{
   MqlRates r[]; if(!ReadRates(r,RangeBars+3)) return 0;
   double hi=r[2].high, lo=r[2].low;
   for(int i=2;i<RangeBars+2;i++){ hi=MathMax(hi,r[i].high); lo=MathMin(lo,r[i].low); }
   double atr=GetATR(1); if(atr<=0) return 0;
   double body=MathAbs(r[1].close-r[1].open);
   if(body<MinBodyATR*atr) return 0;
   if(r[1].close>hi && CandleBullish(r[1])) return 1;
   if(r[1].close<lo && CandleBearish(r[1])) return -1;
   return 0;
}

int SignalRetest()
{
   MqlRates r[]; if(!ReadRates(r,RangeBars+RetestLookbackBars+4)) return 0;
   double hi=r[RetestLookbackBars+2].high, lo=r[RetestLookbackBars+2].low;
   for(int i=RetestLookbackBars+2;i<RetestLookbackBars+RangeBars+2;i++){hi=MathMax(hi,r[i].high);lo=MathMin(lo,r[i].low);}
   double atr=GetATR(1); if(atr<=0) return 0;
   // Approximation: breakout occurred recently; latest closed candle retests old range boundary and closes back beyond it.
   for(int k=2;k<=RetestLookbackBars+1;k++)
   {
      if(r[k].close>hi && r[1].low<=hi+RetestToleranceATR*atr && r[1].close>hi && CandleBullish(r[1])) return 1;
      if(r[k].close<lo && r[1].high>=lo-RetestToleranceATR*atr && r[1].close<lo && CandleBearish(r[1])) return -1;
   }
   return 0;
}

int SignalPullback()
{
   MqlRates r[]; if(!ReadRates(r,4)) return 0;
   double f=0,s=0,atr=GetATR(1);
   if(atr<=0 || !ReadValue(hFast,1,f) || !ReadValue(hSlow,1,s)) return 0;
   int trend=TrendDirection();
   if(trend==1 && f>s && r[1].low<=f+PullbackToleranceATR*atr && r[1].close>f && CandleBullish(r[1])) return 1;
   if(trend==-1 && f<s && r[1].high>=f-PullbackToleranceATR*atr && r[1].close<f && CandleBearish(r[1])) return -1;
   return 0;
}

int GetSignal()
{
   int trend=TrendDirection(), sig=0;
   if(SignalMode==SIGNAL_BREAKOUT && EnableBreakout) sig=SignalBreakout();
   else if(SignalMode==SIGNAL_RETEST && EnableRetest) sig=SignalRetest();
   else if(SignalMode==SIGNAL_EMA_PULLBACK && EnableEMAPullback) sig=SignalPullback();
   else if(SignalMode==SIGNAL_ANY_ENABLED)
   {
      if(EnableRetest) sig=SignalRetest();
      if(sig==0 && EnableEMAPullback) sig=SignalPullback();
      if(sig==0 && EnableBreakout) sig=SignalBreakout();
   }
   if(sig==1 && (!AllowBuy || trend!=1)) return 0;
   if(sig==-1 && (!AllowSell || trend!=-1)) return 0;
   return sig;
}

bool PlaceTrade(int direction,double entry,double sl,double tp,double riskMoney,bool pending)
{
   double lots=LotsForRisk(entry,sl,riskMoney);
   if(lots<=0) return false;
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   bool ok=false;
   if(!pending)
   {
      if(direction>0) ok=trade.Buy(lots,_Symbol,0,sl,tp,"FMG main");
      else ok=trade.Sell(lots,_Symbol,0,sl,tp,"FMG main");
   }
   else
   {
      if(direction>0) ok=trade.BuyLimit(lots,entry,_Symbol,sl,tp,ORDER_TIME_GTC,0,"FMG layer");
      else ok=trade.SellLimit(lots,entry,_Symbol,sl,tp,ORDER_TIME_GTC,0,"FMG layer");
   }
   if(!ok) Print("Order failed: ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
   return ok;
}

void OpenBasket(int dir)
{
   if(!SpreadOK() || DailyLock() || EquityLock()) return;
   if(ApproxOpenRiskPercent()+BasketRiskPercent>MaxTotalOpenRiskPercent) return;
   if(CountOurPositions()+CountOurOrders()>=MaxPositions) return;
   double atr=GetATR(1); if(atr<=0) return;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double entry=(dir>0?ask:bid);
   double sl=(dir>0?entry-1.5*atr:entry+1.5*atr);
   double oneR=MathAbs(entry-sl);
   double tp=(dir>0?entry+MainTargetR*oneR:entry-MainTargetR*oneR);
   double basketRisk=AccountInfoDouble(ACCOUNT_EQUITY)*BasketRiskPercent/100.0;
   bool doMarket=(EntryMethod==ENTRY_MARKET_ONLY || EntryMethod==ENTRY_MARKET_AND_LAYERS);
   bool doLayers=(EntryMethod==ENTRY_LIMIT_LAYERS_ONLY || EntryMethod==ENTRY_MARKET_AND_LAYERS);
   int slots=MathMax(1,LayerCount+(doMarket?1:0));
   double perRisk=basketRisk/slots;
   if(doMarket) PlaceTrade(dir,entry,sl,tp,perRisk,false);
   if(doLayers && LayerCount>0)
   {
      for(int i=1;i<=LayerCount;i++)
      {
         double frac=(double)i/(LayerCount+1.0);
         double layerDist=oneR*(LayerStartR+(LayerEndR-LayerStartR)*frac);
         double layerEntry=(dir>0?entry-layerDist:entry+layerDist);
         // Limits are placed between current price and common SL. All layers share the basket stop.
         if(dir>0 && layerEntry<=sl) continue;
         if(dir<0 && layerEntry>=sl) continue;
         double layerTP=(dir>0?layerEntry+MainTargetR*oneR:layerEntry-MainTargetR*oneR);
         PlaceTrade(dir,layerEntry,sl,layerTP,perRisk,true);
      }
   }
}

void ManagePositions()
{
   double atr=GetATR(1); if(atr<=0) return;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!ticket || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol || (ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      long type=PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN), sl=PositionGetDouble(POSITION_SL), tp=PositionGetDouble(POSITION_TP);
      double vol=PositionGetDouble(POSITION_VOLUME);
      double initialR=0;
      if(GlobalVariableCheck(GVInitialRisk(ticket))) initialR=GlobalVariableGet(GVInitialRisk(ticket));
      if(initialR<=0 && sl>0){initialR=MathAbs(open-sl);GlobalVariableSet(GVInitialRisk(ticket),initialR);}
      if(initialR<=0) continue;
      double px=(type==POSITION_TYPE_BUY?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK));
      double profitDist=(type==POSITION_TYPE_BUY?px-open:open-px);
      if(UsePartialClose && profitDist>=PartialCloseAtR*initialR && !GlobalVariableCheck(GVPartial(ticket)))
      {
         double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
         double closeVol=NormalizeVolume(vol*PartialClosePercent/100.0);
         if(closeVol>=vmin && closeVol<vol && trade.PositionClosePartial(ticket,closeVol))
            GlobalVariableSet(GVPartial(ticket),1);
         else if(closeVol>=vol) GlobalVariableSet(GVPartial(ticket),1);
      }
      double newSL=sl;
      if(UseBreakEven && profitDist>=BreakEvenAtR*initialR)
      {
         double be=open+(type==POSITION_TYPE_BUY?1:-1)*2*_Point;
         if(type==POSITION_TYPE_BUY && (sl<be || sl==0)) newSL=MathMax(newSL,be);
         if(type==POSITION_TYPE_SELL && (sl>be || sl==0)) newSL=(newSL==0?be:MathMin(newSL,be));
      }
      if(UseTrailingStop && profitDist>=TrailStartR*initialR)
      {
         double tr=(type==POSITION_TYPE_BUY?px-TrailATRMultiplier*atr:px+TrailATRMultiplier*atr);
         if(type==POSITION_TYPE_BUY && tr>newSL) newSL=tr;
         if(type==POSITION_TYPE_SELL && (newSL==0 || tr<newSL)) newSL=tr;
      }
      if(newSL>0 && MathAbs(newSL-sl)>_Point)
      {
         trade.SetExpertMagicNumber(MagicNumber);
         if(!trade.PositionModify(ticket,newSL,tp)) Print("Modify failed ",ticket,": ",trade.ResultRetcodeDescription());
      }
   }
}

void CancelPendingWhenLocked()
{
   if(!DailyLock() && !EquityLock()) return;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);
      if(t && OrderSelect(t) && OrderGetString(ORDER_SYMBOL)==_Symbol && (ulong)OrderGetInteger(ORDER_MAGIC)==MagicNumber)
         trade.OrderDelete(t);
   }
}

int OnInit()
{
   initialEquity=AccountInfoDouble(ACCOUNT_BALANCE);
   dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   dayKey=MakeDayKey(TimeCurrent());
   hFast=iMA(_Symbol,SignalTF,FastEMA,0,MODE_EMA,PRICE_CLOSE);
   hSlow=iMA(_Symbol,SignalTF,SlowEMA,0,MODE_EMA,PRICE_CLOSE);
   hTrendFast=iMA(_Symbol,TrendTF,FastEMA,0,MODE_EMA,PRICE_CLOSE);
   hTrendSlow=iMA(_Symbol,TrendTF,SlowEMA,0,MODE_EMA,PRICE_CLOSE);
   hATR=iATR(_Symbol,SignalTF,ATRPeriod);
   if(hFast==INVALID_HANDLE || hSlow==INVALID_HANDLE || hTrendFast==INVALID_HANDLE || hTrendSlow==INVALID_HANDLE || hATR==INVALID_HANDLE)
      return INIT_FAILED;
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hFast!=INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow!=INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hTrendFast!=INVALID_HANDLE) IndicatorRelease(hTrendFast);
   if(hTrendSlow!=INVALID_HANDLE) IndicatorRelease(hTrendSlow);
   if(hATR!=INVALID_HANDLE) IndicatorRelease(hATR);
}

void OnTick()
{
   UpdateDayBaseline();
   ManagePositions();
   CancelPendingWhenLocked();
   if(DailyLock() || EquityLock() || !SpreadOK()) return;
   if(!IsNewBar()) return;
   if(CountOurPositions()+CountOurOrders()>=MaxPositions) return;
   int sig=GetSignal();
   if(sig!=0) OpenBasket(sig);
}
