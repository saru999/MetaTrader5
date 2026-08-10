//+------------------------------------------------------------------+
//| BBbreakToLine.mq5                                                |
//| MT4 -> MT5 conversion                                             |
//| Original: BBbreakToLine.mq4                                      |
//+------------------------------------------------------------------+
#property copyright "Copyright (c) 2026, saru999"
#property link      "http://forex.toyolab.com/"
#property version   "1.00"

#include <Trade/Trade.mqh>

CTrade trade;

// マジックナンバー
input long Magic = 20240905;
string EAname = "BBbreakToLine";

// Send_to_Line
string Send_Massage = "fromMT5";
input string Line_token = "";   // 現在は未使用。LINE Notifyはサービス終了済み

// 外部パラメータ
input double Lots = 0.1;        // 売買ロット数
input int ExpMin = 60;          // ポジション決済までの時間(分)
input int ExitHour = 22;        // ポジション決済時刻(時)

// テクニカル指標の設定
#define MaxBars 3
double BB_U[MaxBars];
double BB_L[MaxBars];
input int BBPeriod = 25;        // ボリンジャーバンドの期間
input double BBDev = 3.0;       // 標準偏差の倍率

// MT5ではiBands()は「値」ではなくインジケーターハンドルを返す
int BBHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| 指定したポジションが、このEAのものか                             |
//+------------------------------------------------------------------+
bool IsMyPosition()
{
   if(!PositionSelect(_Symbol))
      return false;

   long magic = PositionGetInteger(POSITION_MAGIC);
   return (magic == Magic);
}

//+------------------------------------------------------------------+
//| 現在のポジション量                                               |
//| 買い:+Lots、売り:-Lots、なし:0                                  |
//+------------------------------------------------------------------+
double MyPositionOpenLots()
{
   if(!IsMyPosition())
      return 0.0;

   double volume = PositionGetDouble(POSITION_VOLUME);
   long type = PositionGetInteger(POSITION_TYPE);

   if(type == POSITION_TYPE_BUY)
      return volume;

   if(type == POSITION_TYPE_SELL)
      return -volume;

   return 0.0;
}

//+------------------------------------------------------------------+
//| 現在のポジション保有時刻                                         |
//+------------------------------------------------------------------+
datetime MyPositionOpenTime()
{
   if(!IsMyPosition())
      return 0;

   return (datetime)PositionGetInteger(POSITION_TIME);
}

//+------------------------------------------------------------------+
//| ポジション決済                                                   |
//+------------------------------------------------------------------+
bool MyPositionClose()
{
   if(!IsMyPosition())
      return false;

   if(!trade.PositionClose(_Symbol))
   {
      Print("PositionClose failed. retcode=",
            trade.ResultRetcode(), " ",
            trade.ResultRetcodeDescription());
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| テクニカル指標の更新                                             |
//+------------------------------------------------------------------+
void RefreshIndicators()
{
   ArrayInitialize(BB_U, 0.0);
   ArrayInitialize(BB_L, 0.0);

   // Upper=buffer 1, Lower=buffer 2
   if(CopyBuffer(BBHandle, 1, 0, MaxBars, BB_U) != MaxBars)
   {
      Print("CopyBuffer Upper failed. error=", GetLastError());
      return;
   }

   if(CopyBuffer(BBHandle, 2, 0, MaxBars, BB_L) != MaxBars)
   {
      Print("CopyBuffer Lower failed. error=", GetLastError());
      return;
   }
}

//+------------------------------------------------------------------+
//| 終値が指標を上抜け                                               |
//+------------------------------------------------------------------+
bool CrossUpClose(double &ind2[], int shift)
{
   double close_prev = iClose(_Symbol, _Period, shift + 1);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   return (close_prev <= ind2[shift + 1] &&
           ask > ind2[shift]);
}

//+------------------------------------------------------------------+
//| 終値が指標を下抜け                                               |
//+------------------------------------------------------------------+
bool CrossDownClose(double &ind2[], int shift)
{
   double close_prev = iClose(_Symbol, _Period, shift + 1);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   return (close_prev >= ind2[shift + 1] &&
           bid < ind2[shift]);
}

//+------------------------------------------------------------------+
//| エントリー関数                                                   |
//+------------------------------------------------------------------+
int EntrySignal(int pos_id)
{
   double pos = MyPositionOpenLots();

   int ret = 0;

   // 買いシグナル
   if(pos <= 0 && CrossDownClose(BB_L, 1))
      ret = 1;

   // 売りシグナル
   if(pos >= 0 && CrossUpClose(BB_U, 1))
      ret = -1;

   return ret;
}

//+------------------------------------------------------------------+
//| エグジット関数                                                   |
//+------------------------------------------------------------------+
void ExitPosition(int pos_id)
{
   double pos = MyPositionOpenLots();

   // 一定時間経過後に決済
   if(pos != 0 &&
      TimeCurrent() - MyPositionOpenTime() >= ExpMin * 60)
   {
      MyPositionClose();
      return;
   }

   // 一定時刻に決済
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(pos != 0 && dt.hour == ExitHour)
   {
      MyPositionClose();
      return;
   }
}

//+------------------------------------------------------------------+
//| 初期化関数                                                       |
//+------------------------------------------------------------------+
int OnInit()
{
   Comment("Warning  This is for Demo accounts only");

   // MT5版 iBands
   BBHandle = iBands(_Symbol, _Period, BBPeriod, 0, BBDev, PRICE_CLOSE);

   if(BBHandle == INVALID_HANDLE)
   {
      Print("iBands handle creation failed. error=", GetLastError());
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(Magic);
   trade.SetTypeFillingBySymbol(_Symbol);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 終了処理                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(BBHandle != INVALID_HANDLE)
      IndicatorRelease(BBHandle);

   Comment("");
}

//+------------------------------------------------------------------+
//| ティック時実行関数                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   // テクニカル指標の更新
   RefreshIndicators();

   // 手仕舞い処理
   ExitPosition(0);

   // エントリーシグナル
   int sig_entry = EntrySignal(0);

   // 買い注文
   if(sig_entry > 0)
   {
      // 反対ポジションを閉じる
      if(MyPositionOpenLots() < 0)
         MyPositionClose();

      if(!IsMyPosition())
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

         if(trade.Buy(Lots, _Symbol, ask, 0, 0, EAname))
         {
            Alert("trade.Buy()");
            Comment("trade.Buy()");
            Print("BB-BreakDown ", _Symbol,
                  " OrderSend(BUY) Period=", _Period);
         }
         else
         {
            Print("Buy failed. retcode=",
                  trade.ResultRetcode(), " ",
                  trade.ResultRetcodeDescription());
         }
      }
   }

   // 売り注文
   if(sig_entry < 0)
   {
      // 反対ポジションを閉じる
      if(MyPositionOpenLots() > 0)
         MyPositionClose();

      if(!IsMyPosition())
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

         if(trade.Sell(Lots, _Symbol, bid, 0, 0, EAname))
         {
            Alert("trade.Sell()");
            Comment("trade.Sell()");
            Print("BB-BreakUp ", _Symbol,
                  " OrderSend(SELL) Period=", _Period);
         }
         else
         {
            Print("Sell failed. retcode=",
                  trade.ResultRetcode(), " ",
                  trade.ResultRetcodeDescription());
         }
      }
   }

   // MT4版の Sleep(60*1000) は削除。
   // MT5のOnTick()を1分停止させるとEA全体の応答が悪くなるため。
}
