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
    puts "errorCode == \"" + token["errorCode"].to_s + "\""
    @access_token = ForceToken.from_hash(oauth2_client, { :access_token => token, :refresh_token =>  refresh, :header_format => 'OAuth %s' } )
    puts "Moving on."
  else
    puts "No Token, or error !"
    puts "errorCode == \"" + token["errorCode"].to_s + "\""
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

#  query = "select Opportunity.Exony_Opportunity_ID__c, Opportunity.Name, StageName, Amount, CreatedDate, CreatedBy.Name from OpportunityHistory where Opportunity.Name = 'Bell - Bedrock Phase 1 (IBM CA)'"
  query = "select Opportunity.Exony_Opportunity_ID__c, Opportunity.Name, StageName, Amount, CreatedDate, CreatedBy.Name from OpportunityHistory where CreatedDate > LAST_N_QUARTERS:4"
  puts "Running query"
  @opportunities = @access_token.get("#{@instance_url}/services/data/v20.0/query/?q=#{CGI::escape(query)}").parsed

  puts "There are "+ @opportunities['records'].count.to_s + " Opportunity Edits"

  resultset=[]

  # Build an array of date, updater
  @opportunities['records'].each do |opportunity|

    resultset.push [Date.strptime(opportunity["CreatedDate"], "%Y-%m-%d"), opportunity['CreatedBy']['Name']]

  end
  resultset.sort!
  puts "We have:" + resultset.to_s + "<END>"


  # New approach
  @data = Hash.new(0)
  @data[['earliest']]=resultset[0][0]

  puts "Earliest record is " + @data[['earliest']].to_s
  resultset.each do | record |
    @data[[record[0], record[1]]] += 1
  end

  puts "This is the data :"+ @data.to_s + "<END>"


  # Aggregate array to count all data entries for each date
  aggregated=[]
  lastdate=nil
  count=0

  resultset.each do | record |

    if lastdate == nil
      lastdate=record[0]
    end

    if lastdate != record[0]
      aggregated.push [lastdate, count]
      lastdate = record[0]
      count = 1
    else
      count += 1
    end

  end

  if aggregated.empty? || lastdate !=  resultset[-1][0]
    aggregated.push [lastdate, count]
  end

  # Now flatten the time series

  @data = []
  lastdate = nil # horrible defensive coding by old infirm man

  aggregated.each do | record |

    if @data == []
      puts "Initialising flattener:" + record[0].to_s + "<END>"
      @data.push record
    else
      if record[0] != lastdate + 1
        lastdate += 1
        while lastdate < record[0]
          @data.push [lastdate, 0]
          lastdate += 1
        end
      end
      @data.push record
    end
    lastdate = record[0]
  end

  # Send it to the web
  puts "Invoking Renderer"
  erb :index
end

get '/detail' do
  @opportunity = @access_token.get("#{@instance_url}/services/data/v20.0/sobjects/Opportunity/#{params[:id]}").parsed
  
  erb :detail
end

post '/action' do
  if params[:new]
    @action_name = 'create'
    @action_value = 'Create'
    
    @opportunity = Hash.new
    @opportunity['Id'] = ''
    @opportunity['Name'] = ''
    @opportunity['Industry'] = ''
    @opportunity['TickerSymbol'] = ''

    done = :edit
  elsif params[:edit]
    @opportunity = @access_token.get("#{@instance_url}/services/data/v20.0/sobjects/Opportunity/#{params[:id]}").parsed
    @action_name = 'update'
    @action_value = 'Update'

    done = :edit
  elsif params[:delete]
    @access_token.delete("#{@instance_url}/services/data/v20.0/sobjects/Opportunity/#{params[:id]}")
    @action_value = 'Deleted'
    
    @result = Hash.new
    @result['id'] = params[:id]

    done = :done
  end  
  
  erb done
end

post '/opportunity' do
  if params[:create]
    body = {"Name"   => params[:Name], 
      "Industry"     => params[:Industry], 
      "TickerSymbol" => params[:TickerSymbol]}.to_json

    @result = @access_token.post("#{@instance_url}/services/data/v20.0/sobjects/Opportunity/",
      {:body => body, 
       :headers => {'Content-type' => 'application/json'}}).parsed
    @action_value = 'Created'
  elsif params[:update]
    body = {"Name"   => params[:Name], 
      "Industry"     => params[:Industry], 
      "TickerSymbol" => params[:TickerSymbol]}.to_json

    # No response for an update
    @access_token.post("#{@instance_url}/services/data/v20.0/sobjects/Opportunity/#{params[:id]}?_HttpMethod=PATCH",
      {:body => body, 
       :headers => {'Content-type' => 'application/json'}})
    @action_value = 'Updated'
    
    @result = Hash.new
    @result['id'] = params[:id]
  end  
  
  erb :done
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
