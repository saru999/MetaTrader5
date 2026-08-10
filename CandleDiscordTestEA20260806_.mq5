#property copyright ""
#property version   "1.00"
#property description "New candle -> Discord notification test EA"

// ==============================================================
// CandleDiscordTestEA
//
// 目的:
//   新しいローソク足が発生したらDiscordへ送信する。
//   Discord送信に成功したローソク足にはチャート上に印を付ける。
//
// 注意:
//   WebRequest() はEAから実行する。
//   MT5: ツール -> オプション -> エキスパートアドバイザ
//   「WebRequestを許可するURL」に https://discord.com/* を追加する。
// ==============================================================

// -------------------------
// Discord設定
// -------------------------
// 実際のWebhook URLはここに直接書かず、EAの設定画面から入力する。
input string DiscordWebhookURL = "";
input int    WebRequestTimeout = 5000;

// -------------------------
// 通知設定
// -------------------------
input bool SendOnStartup = false;

// -------------------------
// チャート上の印
// -------------------------
input bool MarkCandle = true;
input color MarkColor = clrRed;
input int   MarkCode = 234;       // ▼
input int   MarkSize = 2;
input int   MarkOffsetPoints = 20;

// -------------------------
// EA内部状態
// -------------------------
datetime LastBarTime = 0;

// ==============================================================
// JSONエスケープ
// ==============================================================
string EscapeJSON(string text)
{
   StringReplace(text, "\\", "\\\\");
   StringReplace(text, "\"", "\\\"");
   StringReplace(text, "\r", "");
   StringReplace(text, "\n", "\\n");
   StringReplace(text, "\t", "\\t");

   return text;
}

// ==============================================================
// Discordへメッセージ送信
// ==============================================================
bool SendDiscordMessage(string message)
{
   if(DiscordWebhookURL == "")
   {
      Print("DiscordWebhookURL が設定されていません。");
      return false;
   }

   string json =
      "{\"content\":\"" + EscapeJSON(message) + "\"}";

   string headers =
      "Content-Type: application/json\r\n";

   char data[];
   char result[];
   string result_headers;

   // DiscordへUTF-8で送信
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
      WebRequestTimeout,
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

// ==============================================================
// 指定したローソク足の情報をDiscord用メッセージにする
// shift=0 : 現在形成中の足
// shift=1 : 直前に確定した足
// ==============================================================
string BuildCandleMessage(int shift)
{
   datetime bar_time = iTime(_Symbol, _Period, shift);
   double open_price = iOpen(_Symbol, _Period, shift);
   double high_price = iHigh(_Symbol, _Period, shift);
   double low_price  = iLow(_Symbol, _Period, shift);
   double close_price = iClose(_Symbol, _Period, shift);

   string message =
      "NEW CANDLE\n" +
      _Symbol + " " + EnumToString(_Period) +
      "\nTime: " + TimeToString(bar_time, TIME_DATE | TIME_MINUTES) +
      MQLInfoString(MQL5_PROGRAM_NAME) +
      "\nOpen: " + DoubleToString(open_price, _Digits) +
      "\nHigh: " + DoubleToString(high_price, _Digits) +
      "\nLow: " + DoubleToString(low_price, _Digits) +
      "\nClose: " + DoubleToString(close_price, _Digits);

   return message;
}

// ==============================================================
// 新しいローソク足が発生したか確認
// ==============================================================
bool IsNewBar()
{
   datetime current_bar_time = iTime(_Symbol, _Period, 0);

   if(current_bar_time <= 0)
      return false;

   if(LastBarTime == 0)
   {
      LastBarTime = current_bar_time;
      return false;
   }

   if(current_bar_time != LastBarTime)
   {
      LastBarTime = current_bar_time;
      return true;
   }

   return false;
}

// ==============================================================
// Discord送信成功後、そのローソク足に印を付ける
// ==============================================================
bool MarkSentCandle(int shift)
{
   if(!MarkCandle)
      return true;

   datetime bar_time = iTime(_Symbol, _Period, shift);
   double low_price = iLow(_Symbol, _Period, shift);

   if(bar_time <= 0 || low_price <= 0)
      return false;

   string name =
      "DiscordSent_" +
      _Symbol + "_" +
      EnumToString(_Period) + "_" +
      IntegerToString((long)bar_time);

   if(ObjectFind(0, name) >= 0)
      return true;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double mark_price =
      low_price - point * MarkOffsetPoints;

   if(!ObjectCreate(
      0,
      name,
      OBJ_ARROW,
      0,
      bar_time,
      mark_price
   ))
   {
      Print("印の作成に失敗: ", GetLastError());
      return false;
   }

   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, MarkCode);
   ObjectSetInteger(0, name, OBJPROP_COLOR, MarkColor);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, MarkSize);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);

   ChartRedraw(0);

   return true;
}

// ==============================================================
// 新しいローソク足をDiscordへ送信
// ==============================================================
bool SendNewCandleNotification()
{
   // 新しくできた現在足を通知
   string message = BuildCandleMessage(0);

   Print("新しいローソク足を検出しました。");
   Print(message);

   bool success = SendDiscordMessage(message);

   // Discord送信成功時だけ印を付ける
   if(success)
      MarkSentCandle(0);

   return success;
}

// ==============================================================
// 起動時テスト送信
// ==============================================================
bool SendStartupTest()
{
   string message =
      "MT5 Discord Test\n" +
      _Symbol + " " + EnumToString(_Period) +
      "\nEA started.";

   return SendDiscordMessage(message);
}

// ==============================================================
// EA初期化
// ==============================================================
int OnInit()
{
   if(DiscordWebhookURL == "")
   {
      Print("ERROR: DiscordWebhookURL が設定されていません。");
      return INIT_PARAMETERS_INCORRECT;
   }

   // EAをセットした瞬間の現在足を記録する。
   // これにより、セット直後に「新しい足」と誤判定しない。
   LastBarTime = iTime(_Symbol, _Period, 0);

   if(LastBarTime <= 0)
   {
      Print("ERROR: ローソク足データを取得できません。");
      return INIT_FAILED;
   }

   Print(
      "CandleDiscordTestEA 起動: ",
      _Symbol,
      " ",
      EnumToString(_Period)
   );

   if(SendOnStartup)
      SendStartupTest();

   return INIT_SUCCEEDED;
}

// ==============================================================
// EAメイン処理
// ==============================================================
void OnTick()
{
   if(IsNewBar())
      SendNewCandleNotification();
}

// ==============================================================
// EA終了
// ==============================================================
void OnDeinit(const int reason)
{
   Print("CandleDiscordTestEA 終了: reason=", reason);
}
