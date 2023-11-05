defmodule FonaModem.ModemServer do
  @moduledoc """
  Sends commands to the modem to change settings and make calls
  The modem being used for this is the AdaFruit FONA 3G
  """
  use GenServer
  alias Circuits.UART

  # shape of the state is?
  # client_pid: pid to send messages to, sent in to init
  # uart_pid: the connected modem
  # modem_status: :online? in a good state?

  # Callbacks
  require Logger

  # @network_status_pin 2
  # @power_status_pin 3
  # @ring_indicator_pin 4

  @max_volume 8
  @quick_timeout_ms 500
  @long_timeout_ms 2000

  # 4 seconds seems too long, why are :partial results coming in?
  @rx_framing_timeout 4000

  def start_link(client_pid) do
    Logger.info("[Modem Server] start_link")
    GenServer.start_link(__MODULE__, client_pid, name: ModemServer)
  end

  @impl GenServer
  def init(client_pid) do
    Logger.info("[Modem Server] init")
    key_pin = Application.fetch_env!(:fona_modem, :key_pin)
    dtr_pin = Application.fetch_env!(:fona_modem, :dtr_pin)
    uart_name = Application.fetch_env!(:fona_modem, :uart_name)

    {:ok, uart_pid} = UART.start_link()
    speed = 115_200

    # Mango Pi Pro
    # :ok = UART.open(uart_pid, "ttyS0", speed: 115_200, active: false)
    Logger.info("[Modem Server] open uart at name #{uart_name} at speed #{speed}")

    :ok = UART.open(uart_pid, uart_name, speed: speed, active: false)

    # Pins that can be flipped for sleeping/preventing sleep on the FONA 3G

    # TODO: try a different value
    UART.configure(uart_pid, rx_framing_timeout: @rx_framing_timeout)
    UART.configure(uart_pid, framing: {UART.Framing.Line, separator: "\r\n"})

    modem_status = init_modem(uart_pid)
    Logger.info("[Modem Server] modem status: #{modem_status}")

    {:ok, _response} = set_loudspeaker_volume(uart_pid, @max_volume)

    # Ground the FONA Key pin to disable power saving
    # Tie this pin to ground for 3 to 5 seconds to turn the module on or off.
    {:ok, key} = Circuits.GPIO.open(key_pin, :output)
    Circuits.GPIO.write(key, 0)

    # Ground the DTR pin.  Setting the pin to 1 will sleep the phone and will hopefully hang up a call
    {:ok, dtr} = Circuits.GPIO.open(dtr_pin, :output)
    wake_FONA(dtr)

    state = %{client_pid: client_pid, uart_pid: uart_pid, modem_status: modem_status, dtr: dtr}
    {:ok, state}
  end

  @impl GenServer
  # :play_tone also means the phone was taken off hook
  def handle_call({:play_tone, tone}, {_pid, _reference}, %{uart_pid: uart_pid, dtr: dtr} = state) do
    :ok = wake_FONA(dtr)
    response = play_tone(uart_pid, tone)
    # {:ok, response} = play_tone(uart_pid, tone)

    Logger.info("[Modem Server] response to play tone: #{inspect(response)}")
    state = Map.put(state, :modem_status, :playing_dial_tone)

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:partial, response}, {_pid, _reference}, state) do
    Logger.info("[Modem Server] *PARTIAL* response came in? #{inspect(response)}")

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(:hang_up, {_pid, _reference}, %{uart_pid: uart_pid, dtr: dtr} = state) do
    Logger.info("[Modem Server] handle call :hangup")
    hang_up(uart_pid)
    sleep_FONA(dtr)
    state = Map.put(state, :modem_status, :on_hook)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(
        {:make_phone_call, phone_number},
        {_pid, _reference},
        %{uart_pid: uart_pid} = state
      ) do
    state =
      if String.length(phone_number) >= 7 do
        Logger.info("[Modem Server] handle call :make_phone_call")
        {:ok, response} = make_voice_call(uart_pid, phone_number)
        Logger.info("[Modem Server] voice call response: #{inspect(response)}")
        Map.put(state, :modem_status, :on_voice_call)
      else
        Logger.info(
          "[Modem Server] Mistakes were made.  Don't call phone number: #{phone_number}"
        )

        Map.put(state, :phone_number, "")
      end

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(
        {:send_at_command, command},
        {_pid, _reference},
        %{uart_pid: uart_pid} = state
      ) do
    {:ok, response} = send_command_get_response(uart_pid, command)
    {:reply, {:ok, response}, state}
  end

  # Private methods

  defp init_modem(uart_pid) do
    # 1 – handset
    # 3 – speaker phone

    {:ok, _response} = send_command_get_response(uart_pid, "ATE0\r\n")
    {:ok, _response} = send_command_get_response(uart_pid, "AT+CSDVC=3\r\n")
    {:ok, _response} = send_command_get_response(uart_pid, "AT+CRXGAIN=30000\r\n")
    {:ok, _response} = send_command_get_response(uart_pid, "AT+CTXGAIN=65535\r\n")
    # this is a good way to see if AT even responds
    {:ok, response} = send_command_get_response(uart_pid, "AT+CBC\r\n")

    if String.match?(response, ~r/CBC/), do: :up, else: :down
  end

  defp play_tone(uart_pid, 0) do
    # kill the playing sound
    # no EXT, no =, just CPTONEEXT
    {:ok, response} = send_command_get_response(uart_pid, "AT+CPTONEEXT\r\n")
    Logger.info("[Modem Server] play tone 0 response #{response}")
    {:ok, response}
  end

  defp play_tone(uart_pid, tone) do
    if tone == 2 do
      Logger.info("[Modem Server] playing dial tone")
    else
      Logger.info("[Modem Server] playing ext tone: #{tone}")
    end

    {:ok, response} = send_command_get_response(uart_pid, "AT+CPTONEEXT=#{tone}\r\n")
    Logger.info("[Modem Server] play tone response #{response}")
    {:ok, response}
  end

  defp sleep_FONA(dtr) do
    Circuits.GPIO.write(dtr, 1)
  end

  defp wake_FONA(dtr) do
    Circuits.GPIO.write(dtr, 0)
  end

  defp hang_up(uart_pid) do
    Logger.info("[Modem Server] hanging up")
    # ATH is ignored unless AT+CVHU=0 is set.  use AT+CHUP instead
    {:ok, _response} = send_command_get_response(uart_pid, "AT+CHUP\r\n")
    # VOICE CALL:END:000017 <- (timestamp)
    # kill the playing sound
    play_tone(uart_pid, 0)
  end

  defp set_loudspeaker_volume(uart_pid, volume) do
    Logger.info("[Modem Server] set loudspeaker volume to: #{volume}")
    # UART.write(pid, "AT+CPTONE=18\r\n")
    {:ok, _response} = send_command_get_response(uart_pid, "AT+CSDVC=#{volume}\r\n")
  end

  defp make_voice_call(uart_pid, phone_number) do
    call_command = "ATD#{phone_number};\r\n"
    Logger.info("[Modem Server] make voice call using command #{call_command}")
    {:ok, _response} = send_command_get_response(uart_pid, call_command)
  end

  defp send_command_get_response(uart_pid, command) do
    if command != "" do
      Logger.info("sending command: #{command}")
      :ok = UART.write(uart_pid, command)
    end

    # Need to get 2 responses.  First will be blank, second will have response.
    {:ok, response1} = get_response(uart_pid, @quick_timeout_ms)

    if !is_binary(response1),
      do: Logger.warning("unexpected non-string response: #{inspect(response1)}")

    if response1 != "" do
      Logger.info("[Modem Server] command: #{command} 1st response: #{inspect(response1)}")
    end

    {:ok, response2} = get_response(uart_pid, @long_timeout_ms)

    if !is_binary(response2) do
      Logger.warning("unexpected non-string response: #{inspect(response2)}")
      {:ok, to_string(response2)}
    else
      Logger.info("[Modem Server] 2nd response: #{response2}")
      {:ok, response1 <> response2}
    end
  end

  defp get_response(uart_pid, timeout_ms) do
    case UART.read(uart_pid, timeout_ms) do
      {:ok, resp} ->
        case resp do
          {:partial, partial} ->
            Logger.info("partial response! partial: #{partial}")
            {:ok, partial <> get_response(uart_pid, timeout_ms)}

          x when is_binary(x) ->
            {:ok, resp}
        end

      # {:ok, prev_resp <> resp}

      # ** (EXIT) an exception was raised:
      # ** (MatchError) no match of right hand side value: {:error, {:badarg, [{VintageCell.ModemServer, :get_response, 3, [file: 'lib/fona_modem/modem_server.ex', line: 229, error_info: %{cause: {2, :binary, :type, {:partial, <<0>>}}, function: :format_bs_fail, module: :erl_erts_errors}]}, {VintageCell.ModemServer, :send_command_get_response, 2, [file: 'lib/fona_modem/modem_server.ex', line: 206]}, {VintageCell.ModemServer, :request_battery_percent, 1, [file: 'lib/fona_modem/modem_server.ex', line: 145]}, {VintageCell.ModemServer, :init, 1, [file: 'lib/fona_modem/modem_server.ex', line: 55]}, {:gen_server, :init_it, 2, [file: 'gen_server.erl', line: 851]}, {:gen_server, :init_it, 6, [file: 'gen_server.erl', line: 814]}, {:proc_lib, :init_p_do_apply, 3, [file: 'proc_lib.erl', line: 240]}]}}
      #     (fona_modem 0.1.0) lib/fona_modem.ex:54: VintageCell.Worker.init/1
      #     (stdlib 4.3) gen_server.erl:851: :gen_server.init_it/2
      #     (stdlib 4.3) gen_server.erl:814: :gen_server.init_it/6
      #     (stdlib 4.3) proc_lib.erl:240: :proc_lib.init_p_do_apply/3
      # Circuits.UART typespec is missing this return value
      unexpected ->
        err = "<unexpected: #{inspect(unexpected)}"
        Logger.warning(err)
        {:ok, err}
    end
  end
end
