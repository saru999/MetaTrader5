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


//+------------------------------------------------------------------+
//| Discord通知設定                                                   |
//| WebRequestを使ってDiscord Webhookへ送信                           |
//| MT5: ツール -> オプション -> エキスパートアドバイザ              |
//| 「WebRequestを許可するURL」に https://discord.com/* を追加        |
//+------------------------------------------------------------------+
input string DiscordWebhookURL = "https://discord.com/api/webhooks/1535157320479285279/-keYrq9ZsXHtWvnXc4izABd26Sisfx9PI667H14v7ZHaXE7Uz3vTwZD7O1KCbQbAMiOk";
input int    DiscordWebRequestTimeout = 5000;
input bool   SendDiscordOnSignal = true;

//+------------------------------------------------------------------+
//| JSONエスケープ                                                    |
//+------------------------------------------------------------------+
string EscapeJSON(string text)
{
   StringReplace(text, "\\", "\\\\");
   StringReplace(text, "\"", "\\\"");
   StringReplace(text, "\r", "");
   StringReplace(text, "\n", "\\n");
   StringReplace(text, "\t", "\\t");

   return text;
}

//+------------------------------------------------------------------+
//| Discordへメッセージ送信                                           |
//+------------------------------------------------------------------+
bool SendDiscordMessage(string message)
{
   if(DiscordWebhookURL == "")
   {
      Print("Discord: Webhook URLが設定されていません。");
      return false;
   }

   string json =
      "{\"content\":\"" + EscapeJSON(message) + "\"}";

   string headers =
      "Content-Type: application/json\r\n";

   char data[];
   char result[];
   string result_headers;

   // UTF-8でDiscordへ送信
   StringToCharArray(
      json,
      data,
      0,
      StringLen(json),
      CP_UTF8
   );

   ResetLastError();

   int http_code = WebRequest(
      "POST",
      DiscordWebhookURL,
      headers,
      DiscordWebRequestTimeout,
      data,
      result,
      result_headers
   );

   int error_code = GetLastError();

   if(http_code == 204)
   {
      Print("Discord送信成功: ", message);
      return true;
   }

   Print(
      "Discord送信失敗: HTTP=",
      http_code,
      " / LastError=",
      error_code
   );

   if(ArraySize(result) > 0)
   {
      string response =
         CharArrayToString(result, 0, -1, CP_UTF8);

      Print("Discord response: ", response);
   }

   return false;
}

//+------------------------------------------------------------------+
//| BBシグナル用Discordメッセージ作成                                |
//+------------------------------------------------------------------+
string BuildDiscordSignalMessage(string signal_name, string order_name)
{
   datetime bar_time = iTime(_Symbol, _Period, 0);

   string message =
      "BB SIGNAL\n" +
      "Signal: " + signal_name + "\n" +
      "Order: " + order_name + "\n" +
      "Symbol: " + _Symbol + "\n" +
      "Period: " + EnumToString(_Period) + "\n" +
      "Time: " + TimeToString(
         bar_time,
         TIME_DATE | TIME_MINUTES
      ) + "\n" +
      "EA: " + MQLInfoString(MQL_PROGRAM_NAME);

   return message;
}

//+------------------------------------------------------------------+
//| BBシグナルをDiscordへ送信                                         |
//| 注文成功後に呼び出す。Discord失敗でも売買結果は変更しない。       |
//+------------------------------------------------------------------+
bool SendBBSignalToDiscord(string signal_name, string order_name)
{
   if(!SendDiscordOnSignal)
   {
      Print("Discord: シグナル送信OFF");
      return true;
   }

   string message =
      BuildDiscordSignalMessage(signal_name, order_name);

   Print("Discord: シグナル送信開始");
   Print(message);

   bool success = SendDiscordMessage(message);

   if(!success)
      Print("Discord: シグナル送信失敗。ただし注文処理には影響しません。");

   return success;
}

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

            // 注文成功後にDiscordへ通知
            SendBBSignalToDiscord("breakDown", "BUY");
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

            // 注文成功後にDiscordへ通知
            SendBBSignalToDiscord("breakUp", "SELL");
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
