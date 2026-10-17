//+------------------------------------------------------------------+
//| Fusion_MachineGun_PRO.mq5                                        |
//| Risk-first improved implementation; original implementation.    |
//| Attach to a GOLD chart (broker symbol may be XAUUSD, XAUUSDm, etc.)|
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Risk-first Gold EA with selectable breakout, retest and EMA pullback signals."

#include <Trade/Trade.mqh>
CTrade trade;

enum ENUM_ENTRY_METHOD { ENTRY_MARKET_ONLY=0, ENTRY_LIMIT_LAYERS_ONLY=1, ENTRY_MARKET_AND_LAYERS=2 };
enum ENUM_SIGNAL_MODE { SIGNAL_BREAKOUT=0, SIGNAL_RETEST=1, SIGNAL_EMA_PULLBACK=2, SIGNAL_ANY_ENABLED=3 };

input ENUM_ENTRY_METHOD EntryMethod = ENTRY_MARKET_AND_LAYERS;
input ENUM_SIGNAL_MODE SignalMode = SIGNAL_ANY_ENABLED;
input bool EnableBreakout = true;
input bool EnableRetest = true;
input bool EnableEMAPullback = true;
input ENUM_TIMEFRAMES SignalTF = PERIOD_M5;
input ENUM_TIMEFRAMES TrendTF = PERIOD_H1;
input int FastEMA=50, SlowEMA=200, ATRPeriod=14, RangeBars=15, RetestLookbackBars=6;
input double RetestToleranceATR=0.15, PullbackToleranceATR=0.25, MinBodyATR=0.25;
input double BasketRiskPercent=1.0;
input double MaxTotalOpenRiskPercent=2.0;
input double DailyLossLimitPercent=2.0;
input double MaxEquityDrawdownPercent=6.0;
input double MainTargetR=2.0;
input double StopATRMultiplier=1.5;
input int LayerCount=2;
input double LayerStartR=0.35, LayerEndR=0.75;
input double MaxLotPerOrder=0.25;
input int MaxPositions=5;
input int MaxSpreadPoints=60, SlippagePoints=20;
input bool UseBreakEven=true;
input double BreakEvenAtR=1.0;
input bool UseTrailingStop=true;
input double TrailStartR=1.25, TrailATRMultiplier=1.0;
input bool UsePartialClose=true;
input double PartialCloseAtR=1.0, PartialClosePercent=50.0;
input bool AllowBuy=true, AllowSell=true;
input ulong MagicNumber=26101702;

int hFast=INVALID_HANDLE,hSlow=INVALID_HANDLE,hTrendFast=INVALID_HANDLE,hTrendSlow=INVALID_HANDLE,hATR=INVALID_HANDLE;
datetime lastBar=0;
int dayKey=-1;
double dayStartEquity=0,initialEquity=0;

string KeyR(ulong t){return "FMGP_R_"+(string)t;}
string KeyP(ulong t){return "FMGP_P_"+(string)t;}
int DayKey(datetime t){MqlDateTime d;TimeToStruct(t,d);return d.year*10000+d.mon*100+d.day;}
void UpdateDay(){int k=DayKey(TimeCurrent());if(k!=dayKey){dayKey=k;dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);}}
bool DailyLocked(){UpdateDay();return dayStartEquity>0 && (dayStartEquity-AccountInfoDouble(ACCOUNT_EQUITY))/dayStartEquity*100.0>=DailyLossLimitPercent;}
bool EquityLocked(){return initialEquity>0 && (initialEquity-AccountInfoDouble(ACCOUNT_EQUITY))/initialEquity*100.0>=MaxEquityDrawdownPercent;}
bool NewBar(){datetime t=iTime(_Symbol,SignalTF,0);if(!t||t==lastBar)return false;lastBar=t;return true;}
bool Val(int h,int shift,double &v){double b[];ArraySetAsSeries(b,true);if(h==INVALID_HANDLE||CopyBuffer(h,0,shift,1,b)!=1)return false;v=b[0];return true;}
double ATR(){double v=0;Val(hATR,1,v);return v;}
int Trend(){double f=0,s=0;if(!Val(hTrendFast,1,f)||!Val(hTrendSlow,1,s))return 0;return f>s?1:(f<s?-1:0);}
bool SpreadOK(){double a=SymbolInfoDouble(_Symbol,SYMBOL_ASK),b=SymbolInfoDouble(_Symbol,SYMBOL_BID);return a>0&&b>0&&(a-b)/_Point<=MaxSpreadPoints;}
double Vol(double lots){double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),mx=MathMin(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),MaxLotPerOrder),st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);if(st<=0)return 0;lots=MathMax(mn,MathMin(mx,lots));return NormalizeDouble(MathFloor(lots/st)*st,2);}
double LotsRisk(double entry,double sl,double money){double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE),tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);if(tv<=0)tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);if(ts<=0||tv<=0||MathAbs(entry-sl)<=0)return 0;return Vol(money/(MathAbs(entry-sl)/ts*tv));}
int OurPositions(){int n=0;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(t&&PositionSelectByTicket(t)&&PositionGetString(POSITION_SYMBOL)==_Symbol&&(ulong)PositionGetInteger(POSITION_MAGIC)==MagicNumber)n++;}return n;}
int OurOrders(){int n=0;for(int i=OrdersTotal()-1;i>=0;i--){ulong t=OrderGetTicket(i);if(t&&OrderSelect(t)&&OrderGetString(ORDER_SYMBOL)==_Symbol&&(ulong)OrderGetInteger(ORDER_MAGIC)==MagicNumber)n++;}return n;}
double OpenRiskPct(){double risk=0;for(int i=PositionsTotal()-1;i>=0;i--){ulong t=PositionGetTicket(i);if(!t||!PositionSelectByTicket(t))continue;if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;double sl=PositionGetDouble(POSITION_SL),op=PositionGetDouble(POSITION_PRICE_OPEN),v=PositionGetDouble(POSITION_VOLUME);if(sl<=0)continue;double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE),tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);if(tv<=0)tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);if(ts>0&&tv>0)risk+=MathAbs(op-sl)/ts*tv*v;}double eq=AccountInfoDouble(ACCOUNT_EQUITY);return eq>0?100*risk/eq:100;}
bool Bull(MqlRates &r){return r.close>r.open;}
bool Bear(MqlRates &r){return r.close<r.open;}

int BreakoutSignal()
{
   MqlRates r[];ArraySetAsSeries(r,true);if(CopyRates(_Symbol,SignalTF,0,RangeBars+3,r)<RangeBars+3)return 0;
   double hi=r[2].high,lo=r[2].low;for(int i=2;i<RangeBars+2;i++){hi=MathMax(hi,r[i].high);lo=MathMin(lo,r[i].low);}
   double a=ATR();if(a<=0||MathAbs(r[1].close-r[1].open)<MinBodyATR*a)return 0;
   if(r[1].close>hi&&Bull(r[1]))return 1;if(r[1].close<lo&&Bear(r[1]))return -1;return 0;
}
int RetestSignal()
{
   MqlRates r[];ArraySetAsSeries(r,true);if(CopyRates(_Symbol,SignalTF,0,RangeBars+RetestLookbackBars+4,r)<RangeBars+RetestLookbackBars+4)return 0;
   double hi=r[RetestLookbackBars+2].high,lo=r[RetestLookbackBars+2].low;
   for(int i=RetestLookbackBars+2;i<RetestLookbackBars+RangeBars+2;i++){hi=MathMax(hi,r[i].high);lo=MathMin(lo,r[i].low);}
   double a=ATR();if(a<=0)return 0;
   for(int k=2;k<=RetestLookbackBars+1;k++){if(r[k].close>hi&&r[1].low<=hi+RetestToleranceATR*a&&r[1].close>hi&&Bull(r[1]))return 1;if(r[k].close<lo&&r[1].high>=lo-RetestToleranceATR*a&&r[1].close<lo&&Bear(r[1]))return -1;}
   return 0;
}
int PullbackSignal()
{
   MqlRates r[];ArraySetAsSeries(r,true);if(CopyRates(_Symbol,SignalTF,0,4,r)<4)return 0;
   double f=0,s=0,a=ATR();if(a<=0||!Val(hFast,1,f)||!Val(hSlow,1,s))return 0;int tr=Trend();
   if(tr==1&&f>s&&r[1].low<=f+PullbackToleranceATR*a&&r[1].close>f&&Bull(r[1]))return 1;
   if(tr==-1&&f<s&&r[1].high>=f-PullbackToleranceATR*a&&r[1].close<f&&Bear(r[1]))return -1;return 0;
}
int Signal()
{
   int s=0,tr=Trend();
   if(SignalMode==SIGNAL_BREAKOUT&&EnableBreakout)s=BreakoutSignal();
   else if(SignalMode==SIGNAL_RETEST&&EnableRetest)s=RetestSignal();
   else if(SignalMode==SIGNAL_EMA_PULLBACK&&EnableEMAPullback)s=PullbackSignal();
   else if(SignalMode==SIGNAL_ANY_ENABLED){if(EnableRetest)s=RetestSignal();if(!s&&EnableEMAPullback)s=PullbackSignal();if(!s&&EnableBreakout)s=BreakoutSignal();}
   if((s==1&&(!AllowBuy||tr!=1))||(s==-1&&(!AllowSell||tr!=-1)))return 0;return s;
}
bool Send(int dir,double entry,double sl,double tp,double risk,bool pending)
{
   double lots=LotsRisk(entry,sl,risk);if(lots<=0)return false;
   trade.SetExpertMagicNumber(MagicNumber);trade.SetDeviationInPoints(SlippagePoints);
   bool ok=false;if(!pending){ok=dir>0?trade.Buy(lots,_Symbol,0,sl,tp,"FMGP main"):trade.Sell(lots,_Symbol,0,sl,tp,"FMGP main");}
   else{ok=dir>0?trade.BuyLimit(lots,entry,_Symbol,sl,tp,ORDER_TIME_GTC,0,"FMGP layer"):trade.SellLimit(lots,entry,_Symbol,sl,tp,ORDER_TIME_GTC,0,"FMGP layer");}
   if(!ok)Print("Order rejected: ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());return ok;
}
void OpenBasket(int dir)
{
   if(DailyLocked()||EquityLocked()||!SpreadOK())return;
   if(OpenRiskPct()+BasketRiskPercent>MaxTotalOpenRiskPercent)return;
   double a=ATR();if(a<=0)return;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),entry=dir>0?ask:bid;
   double sl=dir>0?entry-StopATRMultiplier*a:entry+StopATRMultiplier*a,oneR=MathAbs(entry-sl),tp=dir>0?entry+MainTargetR*oneR:entry-MainTargetR*oneR;
   bool market=(EntryMethod!=ENTRY_LIMIT_LAYERS_ONLY),layers=(EntryMethod!=ENTRY_MARKET_ONLY);
   int slots=(market?1:0)+(layers?LayerCount:0);if(slots<=0)return;
   double riskEach=AccountInfoDouble(ACCOUNT_EQUITY)*BasketRiskPercent/100.0/slots;
   if(market)Send(dir,entry,sl,tp,riskEach,false);
   if(layers)for(int i=1;i<=LayerCount;i++)
   {
      double frac=(double)i/(LayerCount+1.0),dist=oneR*(LayerStartR+(LayerEndR-LayerStartR)*frac);
      double le=dir>0?entry-dist:entry+dist;if((dir>0&&le<=sl)||(dir<0&&le>=sl))continue;
      double ltp=dir>0?le+MainTargetR*oneR:le-MainTargetR*oneR;
      Send(dir,le,sl,ltp,riskEach,true);
   }
}
void Manage()
{
   double a=ATR();if(a<=0)return;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);if(!t||!PositionSelectByTicket(t))continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol||(ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;
      long ty=PositionGetInteger(POSITION_TYPE);double op=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL),tp=PositionGetDouble(POSITION_TP),vol=PositionGetDouble(POSITION_VOLUME);
      double r=GlobalVariableCheck(KeyR(t))?GlobalVariableGet(KeyR(t)):0;if(r<=0&&sl>0){r=MathAbs(op-sl);GlobalVariableSet(KeyR(t),r);}if(r<=0)continue;
      double px=ty==POSITION_TYPE_BUY?SymbolInfoDouble(_Symbol,SYMBOL_BID):SymbolInfoDouble(_Symbol,SYMBOL_ASK),move=ty==POSITION_TYPE_BUY?px-op:op-px;
      if(UsePartialClose&&move>=PartialCloseAtR*r&&!GlobalVariableCheck(KeyP(t))){double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),cv=Vol(vol*PartialClosePercent/100.0);if(cv>=mn&&cv<vol&&trade.PositionClosePartial(t,cv))GlobalVariableSet(KeyP(t),1);}
      double ns=sl;
      if(UseBreakEven&&move>=BreakEvenAtR*r){double be=op+(ty==POSITION_TYPE_BUY?1:-1)*2*_Point;if(ty==POSITION_TYPE_BUY&&(sl==0||be>ns))ns=be;if(ty==POSITION_TYPE_SELL&&(sl==0||be<ns))ns=be;}
      if(UseTrailingStop&&move>=TrailStartR*r){double tr=ty==POSITION_TYPE_BUY?px-TrailATRMultiplier*a:px+TrailATRMultiplier*a;if(ty==POSITION_TYPE_BUY&&tr>ns)ns=tr;if(ty==POSITION_TYPE_SELL&&(ns==0||tr<ns))ns=tr;}
      if(ns>0&&MathAbs(ns-sl)>_Point){trade.SetExpertMagicNumber(MagicNumber);if(!trade.PositionModify(t,ns,tp))Print("Stop update failed: ",trade.ResultRetcodeDescription());}
   }
}
void ClearPendingIfLocked(){if(!DailyLocked()&&!EquityLocked())return;for(int i=OrdersTotal()-1;i>=0;i--){ulong t=OrderGetTicket(i);if(t&&OrderSelect(t)&&OrderGetString(ORDER_SYMBOL)==_Symbol&&(ulong)OrderGetInteger(ORDER_MAGIC)==MagicNumber)trade.OrderDelete(t);}}
void Dashboard()
{
   Comment("Fusion MachineGun PRO\nSymbol: ",_Symbol," | Signal TF: ",EnumToString(SignalTF)," | Trend TF: ",EnumToString(TrendTF),
   "\nBasket risk: ",DoubleToString(BasketRiskPercent,2),"% | Open risk approx: ",DoubleToString(OpenRiskPct(),2),"%", 
   "\nPositions: ",OurPositions()," | Pending orders: ",OurOrders(),
   "\nDaily lock: ",DailyLocked()?"ON":"OFF"," | Equity lock: ",EquityLocked()?"ON":"OFF",
   "\nSpread: ",DoubleToString((SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID))/_Point,1)," points");
}
int OnInit()
{
   initialEquity=AccountInfoDouble(ACCOUNT_BALANCE);dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);dayKey=DayKey(TimeCurrent());
   hFast=iMA(_Symbol,SignalTF,FastEMA,0,MODE_EMA,PRICE_CLOSE);hSlow=iMA(_Symbol,SignalTF,SlowEMA,0,MODE_EMA,PRICE_CLOSE);
   hTrendFast=iMA(_Symbol,TrendTF,FastEMA,0,MODE_EMA,PRICE_CLOSE);hTrendSlow=iMA(_Symbol,TrendTF,SlowEMA,0,MODE_EMA,PRICE_CLOSE);hATR=iATR(_Symbol,SignalTF,ATRPeriod);
   if(hFast==INVALID_HANDLE||hSlow==INVALID_HANDLE||hTrendFast==INVALID_HANDLE||hTrendSlow==INVALID_HANDLE||hATR==INVALID_HANDLE)return INIT_FAILED;
   trade.SetExpertMagicNumber(MagicNumber);trade.SetDeviationInPoints(SlippagePoints);return INIT_SUCCEEDED;
}
void OnDeinit(const int reason){Comment("");if(hFast!=INVALID_HANDLE)IndicatorRelease(hFast);if(hSlow!=INVALID_HANDLE)IndicatorRelease(hSlow);if(hTrendFast!=INVALID_HANDLE)IndicatorRelease(hTrendFast);if(hTrendSlow!=INVALID_HANDLE)IndicatorRelease(hTrendSlow);if(hATR!=INVALID_HANDLE)IndicatorRelease(hATR);}
void OnTick(){UpdateDay();Manage();ClearPendingIfLocked();Dashboard();if(DailyLocked()||EquityLocked()||!SpreadOK())return;if(!NewBar())return;if(OurPositions()+OurOrders()>=MaxPositions)return;int s=Signal();if(s)OpenBasket(s);}
