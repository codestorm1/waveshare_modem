defmodule FonaModem do
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

  # Client API
  #
  def play_tone(tone) do
    GenServer.call(__MODULE__, {:play_tone, tone})
  end

  def play_ext_tone(tone) do
    GenServer.call(__MODULE__, {:play_ext_tone, tone})
  end

  def cancel_ext_tone() do
    GenServer.call(__MODULE__, {:cancel_ext_tone})
  end

  def make_phone_call(phone_number) when is_binary(phone_number) do
    GenServer.call(__MODULE__, {:make_phone_call, phone_number})
  end

  def send_at_command(command) when is_binary(command) do
    GenServer.call(__MODULE__, {:send_at_command, command})
  end

  def hang_up() do
    GenServer.call(__MODULE__, :hang_up)
    # GenServer.cast(__MODULE__, {:insert, event})
  end

  def start_link(state) do
    Logger.info("[Fona Modem] start_link")
    GenServer.start_link(__MODULE__, state, name: FonaModem)
  end

  @impl GenServer
  def init(_init_state) do
    Logger.info("[Fona Modem] init.  pid: #{inspect(self())}")
    key_pin = Application.fetch_env!(:fona_modem, :key_pin)
    dtr_pin = Application.fetch_env!(:fona_modem, :dtr_pin)
    uart_name = Application.fetch_env!(:fona_modem, :uart_name)

    Logger.info("[Fona Modem] key #{key_pin} dtr #{dtr_pin}")

    {:ok, uart_pid} = UART.start_link()
    speed = 115_200

    # Mango Pi Pro
    # :ok = UART.open(uart_pid, "ttyS0", speed: 115_200, active: false)
    Logger.info("[Fona Modem] open uart at name #{uart_name} at speed #{speed}")

    :ok = UART.open(uart_pid, uart_name, speed: speed, active: false)

    # Pins that can be flipped for sleeping/preventing sleep on the FONA 3G

    # TODO: try a different value
    UART.configure(uart_pid, rx_framing_timeout: @rx_framing_timeout)
    UART.configure(uart_pid, framing: {UART.Framing.Line, separator: "\r\n"})

    modem_status = init_modem(uart_pid)
    Logger.info("[Fona Modem] modem status: #{modem_status}")

    {:ok, _response} = set_loudspeaker_volume(uart_pid, @max_volume)

    # Ground the FONA Key pin to disable power saving
    # Tie this pin to ground for 3 to 5 seconds to turn the module on or off.
    {:ok, key} = Circuits.GPIO.open(key_pin, :output)
    Circuits.GPIO.write(key, 0)

    # Ground the DTR pin.  Setting the pin to 1 will sleep the phone and will hopefully hang up a call
    {:ok, dtr} = Circuits.GPIO.open(dtr_pin, :output)
    wake_FONA(dtr)

    state = %{uart_pid: uart_pid, modem_status: modem_status, dtr: dtr}
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:play_tone, tone}, _from, %{uart_pid: uart_pid, dtr: dtr} = state) do
    :ok = wake_FONA(dtr)
    response = do_play_tone(uart_pid, tone)

    Logger.info("[Fona Modem] response to play tone: #{inspect(response)}")
    state = Map.put(state, :modem_status, :playing_tone)

    {:reply, :ok, state}
  end

  def handle_call({:play_ext_tone, tone}, _from, %{uart_pid: uart_pid, dtr: dtr} = state) do
    :ok = wake_FONA(dtr)
    response = do_play_ext_tone(uart_pid, tone)

    Logger.info("[Fona Modem] response to play ext tone: #{inspect(response)}")
    state = Map.put(state, :modem_status, :playing_tone)

    {:reply, :ok, state}
  end

  def handle_call({:cancel_ext_tone}, _from, %{uart_pid: uart_pid, dtr: dtr} = state) do
    :ok = wake_FONA(dtr)
    response = do_cancel_ext_tone(uart_pid)

    Logger.info("[Fona Modem] response to play ext tone: #{inspect(response)}")

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(:hang_up, {_pid, _reference}, %{uart_pid: uart_pid, dtr: dtr} = state) do
    Logger.info("[Fona Modem] handle call :hangup")
    do_hang_up(uart_pid)
    sleep_FONA(dtr)
    state = Map.put(state, :modem_status, :on_hook)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call(
        {:make_phone_call, phone_number},
        _from,
        %{uart_pid: uart_pid} = state
      ) do
    state =
      if String.length(phone_number) >= 7 do
        Logger.info("[Fona Modem] handle call :make_phone_call")
        {:ok, response} = make_voice_call(uart_pid, phone_number)
        Logger.info("[Fona Modem] voice call response: #{inspect(response)}")
        Map.put(state, :modem_status, :on_voice_call)
      else
        Logger.info("[Fona Modem] Mistakes were made.  Don't call phone number: #{phone_number}")

        Map.put(state, :phone_number, "")
      end

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_call({:send_at_command, command}, _from, %{uart_pid: uart_pid} = state) do
    {:ok, response} = send_command_get_response(uart_pid, command)
    {:reply, {:ok, response}, state}
  end

  # Private methods

  defp init_modem(uart_pid) do
    # 1 – handset
    # 3 – speaker phone
    case UART.flush(uart_pid) do
      {:error, error} -> Logger.error("[Fona Modem] error flushing in init #{inspect(error)}")
      _ -> :ok
    end

    # don't echo commands
    {:ok, _response} = send_command_get_response(uart_pid, "ATE0\r\n")
    # allow ATH to hang up voice calls
    {:ok, _response} = send_command_get_response(uart_pid, "AT+CVHU=0\r\n")
    # use handset
    {:ok, _response} = send_command_get_response(uart_pid, "AT+CSDVC=1\r\n")

    # increase gain for sound and microphone
    {:ok, _response} = send_command_get_response(uart_pid, "AT+CRXGAIN=30000\r\n")
    {:ok, _response} = send_command_get_response(uart_pid, "AT+CTXGAIN=65535\r\n")

    # using CBC command to see if AT responds, and if the response is for this command, not a previous one
    {:ok, response} = send_command_get_response(uart_pid, "AT+CBC\r\n")

    if String.match?(response, ~r/CBC/), do: :up, else: :down
  end

  defp do_play_tone(uart_pid, "0") do
    do_play_tone(uart_pid, "10")
  end

  defp do_play_tone(uart_pid, 0) do
    do_play_tone(uart_pid, "10")
  end

  defp do_play_tone(uart_pid, tone) do
    Logger.info("[Fona Modem] playing tone: #{tone}")
    {:ok, response} = send_command_get_response(uart_pid, "AT+CPTONE=#{tone}\r\n")
    {:ok, response}
  end

  defp do_cancel_ext_tone(uart_pid) do
    # kill the playing sound
    {:ok, response} = send_command_get_response(uart_pid, "AT+CPTONEEXT\r\n")
    {:ok, response}
  end

  defp do_play_ext_tone(uart_pid, tone) do
    {:ok, response} = send_command_get_response(uart_pid, "AT+CPTONEEXT=#{tone}\r\n")
    {:ok, response}
  end

  defp sleep_FONA(dtr) do
    # this isn't well-tested
    Circuits.GPIO.write(dtr, 1)
  end

  defp wake_FONA(dtr) do
    # this isn't well-tested
    Circuits.GPIO.write(dtr, 0)
  end

  defp do_hang_up(uart_pid) do
    Logger.info("[Fona Modem] hanging up")
    # ATH is ignored unless AT+CVHU=0 is set.  use AT+CHUP instead
    {:ok, _response} = send_command_get_response(uart_pid, "AT+CHUP\r\n")

    # {:ok, _response} = send_command_get_response(uart_pid, "ATH\r\n")
    # kill the playing sound
    # do_play_tone(uart_pid, 0)
  end

  defp set_loudspeaker_volume(uart_pid, volume) do
    Logger.info("[Fona Modem] set loudspeaker volume to: #{volume}")
    {:ok, _response} = send_command_get_response(uart_pid, "AT+CSDVC=#{volume}\r\n")
  end

  defp make_voice_call(uart_pid, phone_number) do
    call_command = "ATD#{phone_number};\r\n"
    {:ok, _response} = send_command_get_response(uart_pid, call_command)
  end

  defp send_command_get_response(uart_pid, command) do
    if command != "" do
      Logger.info("sending command: #{command}")
      :ok = UART.write(uart_pid, command)
    end

    # Need to get 2 responses.  First will be blank, second will have response.
    {:ok, response1} = get_response(uart_pid, @quick_timeout_ms)

    if !is_binary(response1) do
      Logger.warning("unexpected non-string response: #{inspect(response1)}")
    end

    if response1 != "" do
      Logger.info("[Fona Modem] command: #{command} 1st response: #{inspect(response1)}")
    end

    {:ok, response2} = get_response(uart_pid, @long_timeout_ms)

    Logger.info("[Fona Modem] 2nd response: #{response2}")
    {:ok, response1 <> response2}
  end

  defp get_response(uart_pid, timeout_ms) do
    case UART.read(uart_pid, timeout_ms) do
      {:ok, {:partial, data}} ->
        Logger.info("partial response! partial: #{data}")
        {:ok, next_data} = get_response(uart_pid, timeout_ms)
        {:ok, data <> next_data}

      {:ok, data} ->
        Logger.info("returning data: #{data}")
        {:ok, data}
    end
  end
end
