import Toybox.Communications;
import Toybox.Lang;
import Toybox.Time;

//! Downloads one day of schedule from the proxy and stores it.
//! Pattern from the SDK WebRequest sample; runs in the background service
//! and in the foreground (manual refresh).
(:background)
class Fetcher {
    private var _date as String = "";
    private var _done as Method(code as Number) as Void;

    public function initialize(done as Method(code as Number) as Void) {
        _done = done;
    }

    public function fetch(date as String) as Void {
        _date = date;
        Communications.makeWebRequest(
            Schedule.proxyUrl(),
            { "a" => Schedule.home(), "b" => Schedule.work(), "date" => date },
            {
                :method => Communications.HTTP_REQUEST_METHOD_GET,
                :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
            },
            method(:onReceive)
        );
    }

    public function onReceive(code as Number, data as Dictionary or String or Null) as Void {
        _done.invoke(handle(_date, code, data, Time.now().value()));
    }

    //! Stores a response or its error; returns the code to report.
    //! Static and network-free so unit tests can feed it any response.
    public static function handle(date as String, code as Number, data as Dictionary or String or Null,
                                  now as Number) as Number {
        if (code == 200) {
            if (data instanceof Dictionary && Schedule.isValid(data)) {
                Schedule.save(date, data, now);
                return code;
            }
            code = Communications.INVALID_HTTP_BODY_IN_NETWORK_RESPONSE;
        }
        if (data instanceof Dictionary && "station".equals(data["error"] as Object?) && data["q"] instanceof String) {
            if ("ambiguous".equals(data["reason"] as Object?)) {
                Schedule.saveError(Schedule.ERROR_AMBIGUOUS, suggestion(data["q"] as String, data["options"] as Object?));
            } else {
                Schedule.saveError(Schedule.ERROR_STATION, data["q"] as String);
            }
        } else if (data instanceof Dictionary && "limit".equals(data["error"] as Object?)) {
            Schedule.saveError(Schedule.ERROR_LIMIT, "");
        } else if (isConnectionError(code)) {
            Schedule.saveError(Schedule.ERROR_PHONE, code.toString());
        } else {
            Schedule.saveError(Schedule.ERROR_SERVER, code.toString());
        }
        return code;
    }

    //! What to type instead of an ambiguous name: the first of the proxy's
    //! options as a question ("Перово, Москва?"), the name itself without them.
    public static function suggestion(name as String, options as Object?) as String {
        if (options instanceof Array && options.size() > 0 && options[0] instanceof String) {
            return (options[0] as String) + "?";
        }
        return name;
    }

    //! Phone, Bluetooth or timeout problems (Communications error codes):
    //! the request never got an answer, so "no connection" is accurate.
    public static function isConnectionError(code as Number) as Boolean {
        return (code <= Communications.BLE_ERROR && code >= Communications.BLE_REQUEST_CANCELLED)
            || (code <= Communications.BLE_QUEUE_FULL && code >= Communications.BLE_CONNECTION_UNAVAILABLE)
            || code == Communications.NETWORK_REQUEST_TIMED_OUT
            || code == Communications.REQUEST_CONNECTION_DROPPED;
    }
}
