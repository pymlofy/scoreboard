# Copyright 2011 Exavideo LLC.
# 
# This file is part of Exaboard.
# 
# Exaboard is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# Exaboard is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with Exaboard.  If not, see <http://www.gnu.org/licenses/>.


require 'patchbay'
require 'json'
require 'erubis'
require 'thin'
require 'serialport'

class ClockSettings
    def initialize(period_length, overtime_length, num_periods)
        @period_length = period_length
        @num_periods = num_periods
        @overtime_length = overtime_length
    end

    attr_reader :period_length
    attr_reader :overtime_length
    attr_reader :num_periods
end

def minutes(x)
    x*60*10
end

CLOCK_HOCKEY_REGULAR_SEASON = ClockSettings.new(minutes(20), minutes(5), 3)
CLOCK_HOCKEY_POSTSEASON = ClockSettings.new(minutes(20), minutes(20), 3)
CLOCK_FOOTBALL = ClockSettings.new(minutes(15), 0, 4)
CLOCK_LACROSSE = ClockSettings.new(minutes(30), minutes(4), 2)

# FIXME: need a way to change this more easily than manually editing this file
CLOCK_MODE = CLOCK_HOCKEY_REGULAR_SEASON

class GameClock
    def initialize(preset)
        # Clock value, in tenths of seconds
        @value = 0
        @last_start = nil
        # 15 minutes, in tenths of seconds
        @period_length = preset.period_length
        @overtime_length = preset.overtime_length
        @period_end = @period_length
        @period = 1
        @num_periods = preset.num_periods
    end


    def time_elapsed
        if @last_start
            elapsed = Time.now - @last_start
            # compute the elapsed time in tenths of seconds

            value_now = @value + (elapsed * 10).to_i

            # we won't go past the end of a period without an explicit restart
            if value_now > @period_end
                value_now = @period_end
                @value = value_now
                @last_start = nil
            end

            value_now
        else
            @value
        end
    end

    def period_advance
        pl = @period_length
        if @period+1 > @num_periods
            pl = @overtime_length
        end
        #if time_elapsed == @period_end
            reset_time(pl, @period+1)
        #end
    end

    def reset_period_remaining(tenths)
        @value = @period_end - tenths
    end

    def reset_time(remaining, newperiod)
        if newperiod <= @num_periods
            # normal period
            @value = @period_length - remaining + @period_length*(newperiod-1)
            @period_end = @period_length*(newperiod)
        else
            # overtime
            @value = @overtime_length*(newperiod-@num_periods) - remaining + @period_length*@num_periods
            @period_end = @period_length*@num_periods + @overtime_length*(newperiod-@num_periods)
        end
        if @last_start != nil
            @last_start = Time.now
        end
        @period = newperiod
    end

    def overtime_length=(new_otlen)
        @overtime_length = new_otlen
        reset_time(period_remaining(), @period)
    end

    attr_reader :period
    attr_reader :num_periods
    attr_reader :overtime_length

    def start
        if @value == @period_end
            # FIXME: handle overtimes correctly...
            @period += 1
            if (@period > @num_periods)
                @period_end += @overtime_length
            else
                @period_end += @period_length
            end
        end

        if @last_start == nil
           @last_start = Time.now 
        end
    end

    def stop
        @value = time_elapsed
        @last_start = nil
    end

    def running?
        if @last_start
            true
        else
            false
        end
    end

    def period_remaining=(tenths)
        @period_end = time_elapsed + tenths
    end

    def period_remaining
        @period_end - time_elapsed
    end
end

# the base data structure everything uses is a JSON format object.
# These are here to provide easier access to that data from views.
class TeamHelper
    attr_accessor :flag

    def initialize(team_data, clock)
        @team_data = team_data
        @clock = clock
    end

    def name
        if @team_data['possession']
            "\xe2\x80\xa2" + @team_data['name']
        else
            @team_data['name']
        end
    end

    def fgcolor
        @team_data['fgcolor']
    end

    def bgcolor
        @team_data['bgcolor']
    end

    def color
        bgcolor
    end
    
    def score
        @team_data['score']
    end

    def shots
        @team_data['shotsOnGoal']
    end

    def timeouts
        @team_data['timeoutsLeft'].to_i
    end

    def called_timeout
        @team_data['timeoutNowInUse']
    end

    def penalties
        PenaltyHelper.new(@team_data['penalties'], @clock)
    end

    def strength
        penalties.strength
    end

    def empty_net
        @team_data['emptyNet'] and @team_data['emptyNet'] != 'false'
    end

    def delayed_penalty
        @team_data['delayedPenalty'] and @team_data['delayedPenalty'] != 'false'
    end

    def fontWidth
        @team_data['fontWidth']
    end

    def status
        @team_data['status']
    end

    def status_color
        if @team_data['statusColor'] && @team_data['statusColor'] != ''
            @team_data['statusColor']
        else
            'yellow'
        end
    end
end

class PenaltyHelper
    def initialize(penalty_data, clock)
        @penalty_data = penalty_data
        @clock = clock
    end

    def strength
        s = 5
        @penalty_data['activeQueues'].each_with_index do |queue, i|
            qstart = @penalty_data['activeQueueStarts'][i].to_i
            qlength = queue_length(queue)
            if qlength > 0 and @clock.time_elapsed < qstart + qlength
                s -= 1
            end
        end

        s
    end

    def time_to_strength_change
        result = -1

        @penalty_data['activeQueues'].each_with_index do |queue, i|
            time_remaining_on_queue = -1
            if queue.length > 0
                qstart = @penalty_data['activeQueueStarts'][i].to_i
                qlength = queue_length(queue)
                qend = qstart + qlength
                time_remaining_on_queue = qend - @clock.time_elapsed
            end

            if time_remaining_on_queue > 0
                if time_remaining_on_queue < result or result == -1
                    result = time_remaining_on_queue 
                end
            end
        end

        if result == -1
            result = 0
        end

        result
    end

protected
    def queue_length(q)
        time = 0
        q.each do |penalty|
            time += penalty['time'].to_i
        end
        
        time
    end

end

class AnnounceHelper
    def initialize(announce_array)
        @announce = announce_array
        @announce_handled = false 
        @frames = 0
    end

    def bring_up
        if @announce_handled
            if @announce.length == 0
                @announce_handled = false
            end
            false
        else
            if @announce.length > 0
                @announce_handled = true
                true
            else
                false
            end
        end
    end

    def is_up
        @announce.length > 0
    end

    def next
        STDERR.puts "going to next announce!"
        @frames = 0
        if @announce.length > 0
            @announce.shift
        else
            nil
        end
    end

    def message
        if @announce.length > 0
            @announce[0]
        else
            ''
        end
    end

    attr_accessor :frames
end

class StatusHelper
    def initialize(app)
        @app = app
        @status_up = false
    end

    def text
        @app.status
    end

    def color
        @app.status_color
    end

    def bring_up
        if @app.status != '' && !@status_up
            @status_up = true
            true
        else
            false
        end
    end

    def bring_down
        if @app.status == '' && @status_up
            @status_up = false
            true
        else
            false
        end
    end

    def is_up
        @app.status != '' 
    end
end

class ClockHelper
    def initialize(clock)
        @clock = clock
    end

    def time
        tenths = @clock.period_remaining

        seconds = tenths / 10
        tenths = tenths % 10

        minutes = seconds / 60
        seconds = seconds % 60

        if @clock.overtime_length == 0 && @clock.period > @clock.num_periods
            ''
        elsif minutes > 0
            format '%d:%02d', minutes, seconds
        else
            format ':%02d.%d', seconds, tenths
        end
    end

    def period
        if @clock.period <= @clock.num_periods
            @clock.period.to_s
        elsif @clock.period == @clock.num_periods + 1
            'OT'
        else
            (@clock.period - @clock.num_periods).to_s + 'OT'
        end
    end
end

def parse_clock(time_str)
	frac = 0
	if time_str =~ /(.*)\.(\d+)/
		frac = (("0." + $2).to_f * 1000).to_i
		time_str = $1
	end

	whole = -1
	if time_str =~ /(\d+):(\d+)/
		whole = ($1.to_i) * 60 + ($2.to_i)
	elsif time_str =~ /(\d+)/
		whole = ($1.to_i)
		whole = (whole / 100) * 60 + (whole % 100)
	end
    #time = whole * 1000 + frac
    time = (whole * 1000 + frac) / 100

    if time < 0
        return nil
    end
    return time
end

class ScoreboardApp < Patchbay
    def initialize
        super

        @DATAFILE_NAME='scoreboard_state.dat'
        @clock = GameClock.new(CLOCK_MODE)
        if File.exists?(@DATAFILE_NAME)
            begin
                @teams = load_data
            rescue
                STDERR.puts "failed to load config, initializing it..."
                @teams = initialize_team_config
                save_data
            end
        else
            @teams = initialize_team_config
            save_data
        end
        @announces = []
        @status = ''
        @status_color = 'white'
        @downdist = ''
        @autosync_enabled = false
    end

    attr_reader :status, :status_color

    def initialize_team_config
        # construct a JSON-ish data structure
        [
            {
                # Team name
                'name' => 'UNION',
                # color value to be used for team name display.
                'fgcolor' => '#ffffff',
                'bgcolor' => '#800000',
                # number of points scored by this team
                'score' => 0,

                # shots on goal count (for hockey)
                'shotsOnGoal' => 0,

                # number 
                # timeouts "left" don't include the one currently in use, if any
                'timeoutsLeft' => 3,
                'timeoutNowInUse' => false,

                # penalty queues (for hockey)
                # A penalty consists of player, penalty, length.
                'penalties' => {
                    # Only two players may serve penalties at a time. These arrays
                    # represent the "stacks" of penalties thus formed.
                    'activeQueues' => [ [], [] ],
                    
                    # These numbers represent the start time of each penalty "stack".
                    # 0 = start of game.
                    'activeQueueStarts' => [ 0, 0 ]
                },

                # roster autocompletion list
                'autocompletePlayers' => [
                ],

                'emptyNet' => false,
                'delayedPenalty' => false,
                'possession' => false,
                'fontWidth' => 0,
                'status' => '',
                'statusColor' => ''
            },
            {
                'name' => 'RPI',
                'fgcolor' => '#ffffff',
                'bgcolor' => '#d40000',
                'score' => 0,
                'shotsOnGoal' => 0,
                'timeoutsLeft' => 3,
                'timeoutNowInUse' => false,
                'penalties' => {
                    'announcedQueue' => [],
                    'activeQueues' => [ [], [] ],
                    'activeQueueStarts' => [ 0, 0 ]
                },
                'autocompletePlayers' => [
                ],
                'emptyNet' => false,
                'delayedPenalty' => false,
                'possession' => false,
                'fontWidth' => 0,
                'status' => '',
                'statusColor' => ''
            }
        ]
    end

    put '/team/:id' do
        id = params[:id].to_i

        if id == 0 or id == 1
            Thread.exclusive { @teams[id].merge!(incoming_json) }
            save_data
            render :json => ''
        else
            render :json => '', :status => 404
        end
    end

    get '/team/:id' do
        id = params[:id].to_i
        if id == 0 or id == 1
            render :json => @teams[id].to_json
        else
            render :json => '', :status => 404
        end
    end

    put '/clock' do
        time_str = incoming_json['time_str']
        period = incoming_json['period'].to_i
        period = @clock.period if period <= 0
        time = parse_clock(time_str)
        if (time)
            @clock.reset_time(time, period)
        end
        render :json => ''
    end

    put '/clock/running' do
        if incoming_json['run']
            @clock.start
        else
            @clock.stop
        end

        render :json => ''
    end

    put '/clock/toggle' do
        if @clock.running?
            @clock.stop
        else
            @clock.start
        end

        render :json => ''
    end

    put '/clock/adjust' do
        time_offset = incoming_json['time'].to_i / 100
        time = @clock.period_remaining + time_offset;
        time = 0 if time < 0
        @clock.reset_time(time, @clock.period)

        render :json => ''
    end

    put '/clock/advance' do
        @clock.period_advance

        render :json => ''
    end

    get '/clock' do
        render :json => {
            'running' => @clock.running?,
            'period_remaining' => @clock.period_remaining,
            'period' => @clock.period,
            'time_elapsed' => @clock.time_elapsed
        }.to_json
    end

    get '/autosync' do
        render :json => {
            'enabled' => @autosync_enabled
        }.to_json
    end

    put '/autosync' do
        if incoming_json['enabled']
            @autosync_enabled = true
        else
            @autosync_enabled = false
        end

        render :json => {
            'enabled' => @autosync_enabled
        }.to_json
    end

    post '/announce' do
        if incoming_json.has_key? 'messages'
            @announces.concat(incoming_json['messages'])
        else
            @announces << incoming_json['message']
        end

        render :json => ''
    end

    put '/status' do
        @status = incoming_json['message']
        @status_color = incoming_json['color'] || 'white'
        render :json => ''
    end

    put '/downdist' do 
        @downdist = incoming_json['message']
        @status = @downdist
        @status_color = (@status == 'FLAG') ? 'yellow' : 'white'
        STDERR.puts @downdist
        render :json => ''
    end

    put '/view_command' do
        command_queue << incoming_json
        render :json => ''
    end

    get '/preview' do
        render :svg => @view.render_template
    end

    def view=(view)
        @view = view
        @view.announce = AnnounceHelper.new(@announces)
        @view.status = StatusHelper.new(self)
        @view.away_team = TeamHelper.new(@teams[0], @clock)
        @view.home_team = TeamHelper.new(@teams[1], @clock)
        @view.clock = ClockHelper.new(@clock)
        @view.command_queue = command_queue
    end

    def view
        @view
    end

    self.files_dir = 'public_html'

    attr_reader :clock, :autosync_enabled

    def sync_score(hscore, vscore)
        if hscore == @teams[1]['score'].to_i + 1
            command_queue << { "goal_scored_by" => "/teams/1" }
        end

        if vscore == @teams[0]['score'].to_i + 1
            command_queue << { "goal_scored_by" => "/teams/0" }
        end

        @teams[1]['score'] = hscore
        @teams[0]['score'] = vscore
    end

protected
    def incoming_json
        unless params[:incoming_json]
            inp = environment['rack.input']
            inp.rewind
            params[:incoming_json] = JSON.parse inp.read
        end

        params[:incoming_json]
    end

    def save_data
        File.open(@DATAFILE_NAME, 'w') do |f|
            f.write @teams.to_json
        end
    end

    def load_data
        File.open(@DATAFILE_NAME, 'r') do |f|
            JSON.parse f.read
        end
    end

    def command_queue
        @command_queue ||= []
        @command_queue
    end
end

module TimeHelpers
    # truncate tenths
    def format_time_without_tenths(time)
        seconds = time / 10
        minutes = seconds / 60
        seconds = seconds % 60

        format "%d:%02d", minutes, seconds
    end

    # round up to next second
    def format_time_without_tenths_round(time)
        seconds = (time + 9) / 10
        minutes = seconds / 60
        seconds = seconds % 60

        format "%d:%02d", minutes, seconds
    end

    def format_time_with_tenths_conditional(time)
        tenths = time % 10
        seconds = time / 10
        
        minutes = seconds / 60
        seconds = seconds % 60

        if minutes == 0
            format ":%02d.%d", seconds, tenths
        else
            format "%d:%02d", minutes, seconds
        end
    end
end

module ViewHelpers
    include TimeHelpers
end

class LinearAnimation
    IN = 0
    OUT = 1
    def initialize
        @value = 0
        @total_frames = 0
        @frame = 0
        @direction = IN
        @transition_done_block = nil
    end

    def frame_advance
        if @total_frames > 0
            @frame += 1
            if @direction == IN
                @value = @frame.to_f / @total_frames.to_f
            else
                @value = 1.0 - (@frame.to_f / @total_frames.to_f)
            end

            if @frame == @total_frames
                @frame = 0
                @total_frames = 0

                if @transition_done_block
                    # copy to temporary in case the block calls in or out
                    the_block = @transition_done_block
                    @transition_done_block = nil
                    the_block.call
                end
            end
        end
    end

    def in(frames)
        @frame = 0
        @total_frames = frames
        @direction = IN

        if block_given?
            @transition_done_block = Proc.new { yield }
        end
    end

    def out(frames)
        @frame = 0
        @total_frames = frames
        @direction = OUT

        if block_given?
            @transition_done_block = Proc.new { yield }
        end
    end

    def cut_in
        @value = 1.0
    end

    def cut_out
        @value = 0.0
    end

    attr_reader :value
end

class ScoreboardView
    include ViewHelpers

    def initialize(filename)
        @template = Erubis::PI::Eruby.new(File.read(filename))

        @away_goal_flasher = LinearAnimation.new
        @home_goal_flasher = LinearAnimation.new
        @announce_text_dissolve = LinearAnimation.new
        @global_dissolve = LinearAnimation.new

        @global_dissolve.cut_in # hack
        @announce_text_dissolve.cut_in

        @animations = [ @away_goal_flasher, @home_goal_flasher, 
            @announce_text_dissolve, @global_dissolve ]
    end

    def goal_flash(flasher)
        n_frames = 15
        
        # chain together a bunch of transitions
        flasher.in(n_frames) { 
            flasher.out(n_frames) {
                flasher.in(n_frames) {
                    flasher.out(n_frames) {
                        flasher.in(n_frames) {
                            flasher.out(n_frames) 
                        }
                    }
                }
            }
        }
    end

    def render
        while command_queue.length > 0
            cmd = command_queue.shift
            if (cmd.has_key? 'down')
                @global_dissolve.out(15)
            elsif (cmd.has_key? 'up')
                @global_dissolve.in(15)
            elsif (cmd.has_key? 'announce_next')
                @announce_text_dissolve.out(10) {
                    announce.next
                    @announce_text_dissolve.in(10)
                }
            elsif (cmd.has_key? 'goal_scored_by')
                if cmd['goal_scored_by'] =~ /\/0$/
                    goal_flash(@away_goal_flasher)
                elsif cmd['goal_scored_by'] =~ /\/1$/
                    goal_flash(@home_goal_flasher)
                end
            end
        end

        @animations.each do |ani|
            ani.frame_advance
        end

        announce.frames += 1

        if announce.frames == 90
            announce.next
        end

        render_template
    end

    def render_template
        @template.result(binding)
    end

    def galpha
        (255 * @global_dissolve.value).to_i
    end

    def announce_text_opacity
        @announce_text_dissolve.value
    end

    def away_blink_opacity
        @away_goal_flasher.value
    end

    def home_blink_opacity
        @home_goal_flasher.value
    end

    attr_accessor :announce, :status, :away_team, :home_team, :clock
    attr_accessor :command_queue
end

app = ScoreboardApp.new
app.view = ScoreboardView.new('reilly_scoreboard_fb_hacked_ecac.svg.erb')
Thin::Logging.silent = true
Thread.new { app.run(:Host => '::1', :Port => 3002) }

def start_rs232_sync_thread(app)
    Thread.new do
        begin
            sp = SerialPort.new('/dev/ttyUSB0', 19200)
            string = ''
            last_control = -1
            while true
                byte = sp.read(1)

                if byte.ord < 0x10
                    # parse (string, last_control)
                    if last_control == 2
                        tenths = -1

                        if (string =~ /^(\d\d)\.(\d)/)
                            tenths = $1.to_i * 10 + $2.to_i
                        elsif (string =~ /^(\s\d|\d\d):(\d\d)[^:]/)
                            tenths = $1.to_i * 600 + $2.to_i * 10
                        end

                        STDERR.puts "tenths: #{tenths}"

                        if tenths >= 0 and app.autosync_enabled
                            app.clock.reset_period_remaining(tenths)
                        end
                    end
                    last_control = byte.ord
                    string = ''
                else
                    string << byte
                end
            end
        rescue Exception => e
            STDERR.puts e.inspect
        end
    end
end

def start_drycontact_sync_thread(app)
    # The dry contact is connected to CTS and DTR.
    # CTS is pulled to RTS by a 10k resistor. 
    # So CTS assumes the state of RTS when the contact
    # is open, and the state of DTR when the contact
    # is closed. The switch on a Daktronics AllSport
    # 5000 console closes when the clock is stopped.
    # We will set up RTS and DTR so that we get
    # a logic 1 when the clock is to run and a 0
    # when it is stopped.
    Thread.new do
        sp = SerialPort.new('/dev/ttyS0', 9600)
        sp.rts = 1
        sp.dtr = 0
        last_cts = 1

        while true
            if sp.cts != last_cts
                if app.autosync_enabled
                    if sp.cts == 1
                        # start the clock
                        app.clock.start
                    else
                        # stop the clock
                        app.clock.stop
                    end
                end
                # remember what the last state was
                last_cts = sp.cts
                # delay briefly to allow signal to debounce
                sleep 0.1
            end
            sleep 0.01
        end
    end
end

def parse_eversan_digit_string(string, app)
    if string =~ /(\d{2})(\d{2})(\d)(\d{2})(\d{2})(\d)$/
        minutes = $1.to_i
        seconds = $2.to_i
        tenths = $3.to_i
        hscore = $4.to_i
        vscore = $5.to_i
        period = $6.to_i

	clock_value = minutes * 600 + seconds * 10 + tenths
        if app.autosync_enabled
            app.clock.reset_time(clock_value, period)
            app.sync_score(hscore, vscore)
        end
    end
end

def start_eversan_sync_thread(app)
    Thread.new do
        begin
            sp = SerialPort.new('/dev/ttyACM0', 115200)
            digit_string = ''
            digits = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9']
            loop do
                ch = sp.read(1)
                if digits.include?(ch)
                    digit_string += ch
                else
                    parse_eversan_digit_string(digit_string, app)
                    digit_string = ''
                end
            end
        rescue Exception => e
            STDERR.puts e.inspect
        end
    end
end

start_rs232_sync_thread(app)

dirty_level = 1

def dump_to_file(x)
    File.open("scbd_lastframe", "wb") do |f|
        f.write(x)
    end
end

while true
    # prepare next SVG frame
    data = app.view.render

    # build header with data length and global alpha
    header = [ data.length, app.view.galpha, dirty_level ].pack('LCC')

    # wait for handshake byte from other end
    if STDIN.read(1).nil?
        break
    end

    # send SVG data with header
    STDOUT.write(header)
    STDOUT.write(data)
end
