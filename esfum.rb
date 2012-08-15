require 'date'
require 'rubygems'
require 'sinatra'
require 'oauth2'
require 'json'
require 'cgi'
require 'dalli'
require 'rack/session/dalli' # For Rack sessions in Dalli

$stdout.sync = true

# Dalli is a Ruby client for memcached
def dalli_client
  Dalli::Client.new(nil, :compression => true, :namespace => 'rack.session', :expires_in => 3600)
end

# Use the Dalli Rack session implementation
use Rack::Session::Dalli, :cache => dalli_client

# Set up the OAuth2 client
def oauth2_client
  OAuth2::Client.new(
    ENV['CLIENT_ID'],
    ENV['CLIENT_SECRET'], 
    :site => ENV['LOGIN_SERVER'], 
    :authorize_url =>'/services/oauth2/authorize', 
    :token_url => '/services/oauth2/token',
    :raise_errors => false
  )
end

# Subclass OAuth2::AccessToken so we can do auto-refresh
class ForceToken < OAuth2::AccessToken
  def request(verb, path, opts={}, &block)
    response = super(verb, path, opts, &block)
    if response.status == 401 && refresh_token
      puts "Refreshing access token"
      @token = refresh!.token
      response = super(verb, path, opts, &block)
    end
    response
  end
end

# Filter for all paths except /oauth/callback
before do
  pass if request.path_info == '/oauth/callback'
  
  token         = session['access_token']
  refresh       = session['refresh_token']
  @instance_url = session['instance_url']

  puts "I am:" + request.host + "<END>"
  puts "talking to instance :" + @instance_url + "<END>" unless @instance_url.nil?
  
  if token && !@instance_url.nil?
    puts "There is a token "
    puts token.to_s
    puts "errorCode == \"" + session["errorCode"].to_s + "\"" unless session["errorCode"].nil?
    @access_token = ForceToken.from_hash(oauth2_client, { :access_token => token, :refresh_token =>  refresh, :header_format => 'OAuth %s' } )
    puts "Moving on."
  else
    puts "No Token, or error !"
    puts "errorCode == \"" + session["errorCode"].to_s + "\"" unless session["errorCode"].nil?
    puts "Setting redirect url to: https://#{request.host}/oauth/callback"
    redirect oauth2_client.auth_code.authorize_url(:redirect_uri => "https://#{request.host}/oauth/callback")
  end  
end

after do
  # Token may have refreshed!
  if @access_token && session['access_token'] != @access_token.token
    puts "Putting refreshed access token in session"
    session['access_token'] = @access_token.token
  end
end

get '/oauth/callback' do
  begin
    access_token = oauth2_client.auth_code.get_token(params[:code], 
      :redirect_uri => "https://#{request.host}/oauth/callback")

    session['access_token']  = access_token.token
    session['refresh_token'] = access_token.refresh_token
    session['instance_url']  = access_token.params['instance_url']
    
    redirect '/'
  rescue => exception
    output = '<html><body><tt>'
    output += "Exception: #{exception.message}<br/>"+exception.backtrace.join('<br/>')
    output += '<tt></body></html>'
  end
end

get '/' do

  start = Date.today() - 90

#  query = "select Opportunity.Exony_Opportunity_ID__c, Opportunity.Name, StageName, Amount, CreatedDate, CreatedBy.Name from OpportunityHistory where Opportunity.Name = 'Bell - Bedrock Phase 1 (IBM CA)'"
  query = "select Opportunity.Exony_Opportunity_ID__c, Opportunity.Name, StageName, Amount, CreatedDate, CreatedBy.Name from OpportunityHistory where CreatedDate > " + start.to_s + "T00:00:00Z order by CreatedDate"
  puts "Running query"
  @opportunities = @access_token.get("#{@instance_url}/services/data/v20.0/query/?q=#{CGI::escape(query)}").parsed

  puts "There are "+ @opportunities['records'].count.to_s + " Opportunity Edits"

  resultset=[]

  # Build an array of date, updater
  @opportunities['records'].each do |opportunity|

    resultset.push [Date.strptime(opportunity["CreatedDate"], "%Y-%m-%d"), opportunity['CreatedBy']['Name']]

  end
  puts "We have:" + resultset.to_s + "<END>"

  # Build a hash by date and user
  @data = Hash.new(0)
  @user_list = []
  @earliest_date = Date.parse("2200-01-01")
  total = 0

  resultset.each do | record |
    @data[[record[0], record[1]]] += 1
    total += 1
    @user_list.push record[1] unless @user_list.find_index(record[1])
    @earliest_date = record[0] unless @earliest_date <= record[0]
  end

  @user_list.sort!

  puts "User List is:" + @user_list.to_s
  puts "Earliest record is " + @earliest_date.to_s + "."
  puts "There are " + total.to_s + " updates in the window."
  puts "This is the data :"+ @data.to_s + "<END>"

  # Debug code to test output
  #
  #total = 0
  #@data.each do  | record |
  #  total += record[1]
  #end
  #puts "It sez here there are " + total.to_s + " updates in the window."

  # Prepare easy to consume strings

  end_date = Date.new(Time.now.year, Time.now.month, Time.now.day)
  today = @earliest_date + 1
  @date_list = "new Date(\"" + @earliest_date.to_s + "\")"
  while (today <= end_date)  do
    @date_list += ", new Date(\"" + today.to_s + "\")"
    today += 1
  end

  puts "Javascript date list:" + @date_list + "<END>"

  styles=[      { "stroke" => "#ff9900", "stroke-width"=> 3, "opacity" => 0.8 },
                { "stroke" => "666633", "stroke-width"=> 3, "opacity" => 0.8  },
                { "stroke" => "CCCC99", "stroke-width"=> 3, "opacity" => 0.8  },
                { "stroke" => "FFFFFF", "stroke-width"=> 3, "opacity" => 0.8  },
                { "stroke" => "990033", "stroke-width"=> 3, "opacity" => 0.8  },
                { "stroke" => "92CD00", "stroke-width"=> 3, "opacity" => 0.8  },
                { "stroke" => "FFCF79", "stroke-width"=> 3, "opacity" => 0.8  },
                { "stroke" => "E5E4D7", "stroke-width"=> 3, "opacity" => 0.8  },
                { "stroke" => "2C6700", "stroke-width"=> 3, "opacity" => 0.8  },
                { "stroke" => "6600CC", "stroke-width"=> 3, "opacity" => 0.8  },
                { "stroke" => "FFCC00", "stroke-width"=> 3, "opacity" => 0.8  },
                { "stroke" => "000000", "stroke-width"=> 3, "opacity" => 0.8  },
                { "stroke" => "CC0000", "stroke-width"=> 3, "opacity" => 0.8  }]

  @series_styles, @series_hover = "", ""

  @user_list.each_index do | ind |
    @series_styles = @series_styles +", " unless ind == 0
    @series_hover = @series_hover +", " unless ind == 0

    @series_styles = @series_styles + styles[ind].to_json unless ind > (styles.count - 1)
    @series_hover = @series_hover +"{ \"stroke-width\": 4} " unless ind > (styles.count - 1)
  end

  puts "Styles:" +@seriesStyles + "<END>"
  puts "Hovers:" +@seriesHover + "<END>"

  # Send it to the web
  puts "Invoking Renderer"
  erb :index
end

get '/logout' do
  # First kill the access token
  # (Strictly speaking, we could just do a plain GET on the revoke URL, but
  # then we'd need to pull in Net::HTTP or somesuch)
  @access_token.get(ENV['LOGIN_SERVER']+'/services/oauth2/revoke?token='+session['access_token'])
  # Now save the logout_url
  @logout_url = session['instance_url']+'/secure/logout.jsp'
  # Clean up the session
  session['access_token'] = nil
  session['instance_url'] = nil
  session['field_list'] = nil
  # Now give the user some feedback, loading the logout page into an iframe...
  erb :logout
end

get '/revoke' do
  # For testing - revoke the token, but leave it in place, so we can test refresh
  @access_token.get(ENV['LOGIN_SERVER']+'/services/oauth2/revoke?token='+session['access_token'])
  puts "Revoked token #{@access_token.token}"
  "Revoked token #{@access_token.token}"
end
