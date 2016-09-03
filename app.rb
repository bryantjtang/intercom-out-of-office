require 'sinatra'
require 'json'
require 'active_support/time'
require 'intercom'
require 'nokogiri'


INTERNAL_NOTE_MESSAGE = "Out of office autoresponder: "



post '/' do
  request.body.rewind
  payload_body = request.body.read
  puts "==============================================================="
  puts payload_body
  puts "==============================================================="
  verify_signature(payload_body)
  push = JSON.parse(payload_body)
  puts "Topic Recieved: #{push['topic']}"
  process_out_of_office_response(push) unless is_office_hours
end

def process_out_of_office_response(data)
  puts "Process out of office response....."
  begin
    conversation_id = data["data"]["item"]["id"]
  rescue
    puts "Could not retrieve conversation ID. Abort abort"
    return
  end

  puts "Conversation: #{conversation_id}"
  send_out_of_office_message(conversation_id) unless already_sent_message_in_past_24_hours(conversation_id)
end

def send_out_of_office_message (conversation_id)
  puts "Sending out of office message!"
  admin_id = ENV["bot_admin_id"] 
  message = ENV["message"] || "We are not available at the moment, we'll get back to you as soon as possible"
  init_intercom
  @intercom.conversations.reply(:id => conversation_id, :type => 'admin', :admin_id => admin_id, :message_type => 'comment', :body => message)
  @intercom.conversations.reply(:id => conversation_id, :type => 'admin', :admin_id => admin_id, :message_type => 'note', :body => "#{INTERNAL_NOTE_MESSAGE} #{Time.now.to_i}")
end

def init_intercom
  if @intercom.nil? then
    app_id = ENV["APP_ID"] 
    api_key = ENV["API_KEY"]
    @intercom = Intercom::Client.new(app_id: app_id, api_key: api_key)
  end
end

def already_sent_message_in_past_24_hours (conversation_id)
  init_intercom
  conversation = @intercom.conversations.find(:id => conversation_id)

  conversation.conversation_parts
    .select{|c| c.part_type == "note"}
    .each{|c|
      if(c.body.index(INTERNAL_NOTE_MESSAGE)) then
        str = c.body
        doc = Nokogiri::HTML(str)
        last_note_timestamp = doc.xpath("//text()").to_s.split(" ").last
        begin
          did_post_in_last_24_hours = Time.now.to_i - last_note_timestamp.to_i < 24 * 60 * 60
          puts "did_post_in_last_24_hours #{did_post_in_last_24_hours}"
          return true if did_post_in_last_24_hours
        rescue
        end
      end
    }
  return false
end

def is_office_hours  
  timezone_string = ENV["timezone"] 
  days_of_work = ENV["days_of_work"] # Sunday to Saturday "0111110" 
  time_start = ENV["time_start"] # 24 hour time
  time_stop = ENV["time_stop"]   # 24 hour time

  timezone = nil
  days_of_work = days_of_work || "0111110"
  time_start = time_start || 900
  time_stop = time_stop || 1700

  if not timezone_string.nil? and not timezone_string.empty? then
    begin
      puts "Timezone of #{timezone_string}"
      timezone = ActiveSupport::TimeZone[timezone_string]
    rescue
      puts "no timezone?"
    end
  end

  current_time = Time.now
  puts "Current time #{current_time}"
  if timezone.nil? then
    puts "No timezone"
    time = current_time.hour * 100 + current_time.min;
    day = current_time.wday
  else
    puts "We have a timezone"
    current_time_in_timezone = timezone.at(current_time);
    time = current_time_in_timezone.hour * 100 + current_time_in_timezone.min;
    day = current_time.wday
  end
  while days_of_work.length < 7
    days_of_work += "1"
  end

  puts "Is a work day? #{days_of_work[day]}"

  if time_start.nil? or time_stop.nil? then
    puts "Yes because nothing defined"
  else 
    puts "Current time: #{time}"
    puts "Start time: #{time_start.to_i}"
    puts "Stop  time: #{time_stop.to_i}"
    is_a_workday = (days_of_work[day] == "1")
    is_office_hours = is_a_workday and (time >= time_start.to_i and time <= time_stop.to_i)
    puts "Office hours: #{is_office_hours} based on calculations"
    return is_office_hours
  end
  return true
end

def verify_signature(payload_body)
  secret = ENV["secret"]
  expected = request.env['HTTP_X_HUB_SIGNATURE']

  if secret.nil? || secret.empty? then
    puts "No secret specified so accept all data"
  elsif expected.nil? || expected.empty? then
    puts "Not signed. Not calculating"
  else

    signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), secret, payload_body)
    puts "Expected  : #{expected}"
    puts "Calculated: #{signature}"
    if Rack::Utils.secure_compare(signature, expected) then
      puts "   Match"
    else
      puts "   MISMATCH!!!!!!!"
      return halt 500, "Signatures didn't match!"
    end
  end
end
