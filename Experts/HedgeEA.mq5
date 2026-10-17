//+------------------------------------------------------------------+
//| HedgeEA.mq5                                                      |
//| Simple hedging Expert Advisor for MetaTrader 5                   |
//| - This EA demonstrates a basic hedging approach: open an initial  |
//|   position and open an opposite "hedge" position if price moves  |
//|   against the initial position by a configured number of pips.    |
//| - INPUTS control symbol, lots, hedging distance, SL/TP, etc.      |
//| IMPORTANT: do NOT store account login/password inside this file.  |
//| Use the MT5 terminal's account login and/or MQL5 VPS for 24/7 run |
//+------------------------------------------------------------------+
#property copyright "generated"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- user inputs
input string InpSymbol          = "";      // symbol (empty = current chart symbol)
input double InpLots           = 0.1;      // base lot size
input int    InpHedgeDistance  = 50;       // distance (pips) to open hedge
input double InpHedgeLotsFactor= 1.0;      // hedge lot = base * factor
input int    InpSL_Pips        = 200;      // stop loss in pips
input int    InpTP_Pips        = 400;      // take profit in pips
input int    InpMagicNumber    = 123456;   // magic number
input int    InpSlippage       = 5;        // allowed slippage in points
input bool   InpUseTrailing    = true;     // use trailing logic for combined positions
input int    InpTrailingStartPips = 100;   // start trailing after this many pips
input int    InpTrailingStepPips  = 20;    // trailing step

//--- internal
ulong ticket_initial = 0;
ulong ticket_hedge   = 0;
double point_size;
string symbol_to_trade;

int OnInit()
  {
   if(StringLen(InpSymbol) > 0) symbol_to_trade = InpSymbol;
   else symbol_to_trade = _Symbol;

   point_size = SymbolInfoDouble(symbol_to_trade, SYMBOL_POINT);
   Print("HedgeEA initialized for symbol=", symbol_to_trade);
   return(INIT_SUCCEEDED);
  }

void OnTick()
  {
   static datetime lastOrderTime=0;

   // Ensure trading allowed and symbol is available
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      Print("Automated trading not allowed in terminal settings. Enable 'Allow automated trading'.");
      return;
     }

   if(!SymbolInfoInteger(symbol_to_trade, SYMBOL_SELECT))
     {
      if(!SymbolSelect(symbol_to_trade, true))
         { Print("Failed to select symbol ", symbol_to_trade); return; }
     }

   // If no positions for our magic on this symbol, open initial position (simple example: BUY)
   if(!HasAnyPositions())
     {
      if(TimeCurrent() - lastOrderTime > 60)
        {
         OpenInitialBuy();
         lastOrderTime = TimeCurrent();
        }
     }
   else
     {
      ManageHedging();
      if(InpUseTrailing) ManageTrailing();
     }
  }

bool HasAnyPositions()
  {
   for(int i=0;i<PositionsTotal();i++)
     {
      if(PositionGetTicket(i)>0)
        {
         if(PositionGetInteger(POSITION_MAGIC)==InpMagicNumber && PositionGetString(POSITION_SYMBOL)==symbol_to_trade)
            return true;
        }
     }
   return false;
  }

void OpenInitialBuy()
  {
   double price = SymbolInfoDouble(symbol_to_trade,SYMBOL_ASK);
   double sl = NormalizeDouble(price - InpSL_Pips * point_size, (int)SymbolInfoInteger(symbol_to_trade,SYMBOL_DIGITS));
   double tp = NormalizeDouble(price + InpTP_Pips * point_size, (int)SymbolInfoInteger(symbol_to_trade,SYMBOL_DIGITS));
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   bool ok = trade.PositionOpen(symbol_to_trade,ORDER_TYPE_BUY,InpLots,price,sl,tp);
   if(!ok)
     Print("OpenInitialBuy failed: ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
   else
     {
      ticket_initial = trade.ResultOrder();
      Print("Initial BUY opened, ticket=",ticket_initial);
     }
  }

void ManageHedging()
  {
   // find our positions on this symbol with our magic
   for(int i=0;i<PositionsTotal();i++)
     {
      if(PositionGetTicket(i)>0 && PositionGetString(POSITION_SYMBOL)==symbol_to_trade && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
        {
         long type = PositionGetInteger(POSITION_TYPE);
         double price_open = PositionGetDouble(POSITION_PRICE_OPEN);
         double current = (type==POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol_to_trade,SYMBOL_BID) : SymbolInfoDouble(symbol_to_trade,SYMBOL_ASK);
         double dist_pips = MathAbs(current - price_open) / point_size;

         // if BUY and price moved against (down) >= HedgeDistance => open SELL hedge
         if(type==POSITION_TYPE_BUY && dist_pips >= InpHedgeDistance && ticket_hedge==0)
           {
            OpenHedgeSell();
           }

         // if SELL and price moved against (up) >= HedgeDistance => open BUY hedge
         if(type==POSITION_TYPE_SELL && dist_pips >= InpHedgeDistance && ticket_hedge==0)
           {
            OpenHedgeBuy();
           }
        }
     }
  }

void OpenHedgeSell()
  {
   double price = SymbolInfoDouble(symbol_to_trade,SYMBOL_BID);
   double lots = NormalizeDouble(InpLots * InpHedgeLotsFactor,2);
   double sl = NormalizeDouble(price + InpSL_Pips * point_size, (int)SymbolInfoInteger(symbol_to_trade,SYMBOL_DIGITS));
   double tp = NormalizeDouble(price - InpTP_Pips * point_size, (int)SymbolInfoInteger(symbol_to_trade,SYMBOL_DIGITS));
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   bool ok = trade.PositionOpen(symbol_to_trade,ORDER_TYPE_SELL,lots,price,sl,tp);
   if(!ok)
     Print("OpenHedgeSell failed: ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
   else
     {
      ticket_hedge = trade.ResultOrder();
      Print("Hedge SELL opened, ticket=",ticket_hedge);
     }
  }

void OpenHedgeBuy()
  {
   double price = SymbolInfoDouble(symbol_to_trade,SYMBOL_ASK);
   double lots = NormalizeDouble(InpLots * InpHedgeLotsFactor,2);
   double sl = NormalizeDouble(price - InpSL_Pips * point_size, (int)SymbolInfoInteger(symbol_to_trade,SYMBOL_DIGITS));
   double tp = NormalizeDouble(price + InpTP_Pips * point_size, (int)SymbolInfoInteger(symbol_to_trade,SYMBOL_DIGITS));
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   bool ok = trade.PositionOpen(symbol_to_trade,ORDER_TYPE_BUY,lots,price,sl,tp);
   if(!ok)
     Print("OpenHedgeBuy failed: ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
   else
     {
      ticket_hedge = trade.ResultOrder();
      Print("Hedge BUY opened, ticket=",ticket_hedge);
     }
  }

void ManageTrailing()
  {
   // simple combined trailing: if combined unrealized profit exceeds threshold, move SLs
   double profit = 0.0;
   for(int i=0;i<PositionsTotal();i++)
     {
      if(PositionGetTicket(i)>0 && PositionGetString(POSITION_SYMBOL)==symbol_to_trade && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber)
        {
         profit += PositionGetDouble(POSITION_PROFIT);
        }
     }
   // Example: convert profit to pips by dividing by point value is complex across symbols; keep simple
   // Trailing implementation can be extended by user
  }

//+------------------------------------------------------------------+
