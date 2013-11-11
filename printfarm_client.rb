#!/usr/bin/ruby


require "rubygems"
require "bundler/setup"

require "serialport"
require "rest-client"
require "json"
require "./configuration"


@printers = []

class Printer
  Printer::Idle = 0
  Printer::Printing = 1
  Printer::Finished = 2
  Printer::Failure = 3
  Printer::WaitForReactivation = 4
  
  attr_accessor :uuid, :port, :state, :starttime, :printtime, :server_id
  
  def initialize(port, device, uuid)
    @port = port
    @device = device
    @uuid = uuid
    @printing_thread = nil
    reset!
    puts "new printer registered on #{@device} with ID #{@uuid}"
  end
  
  def reset!
    @state = Printer::Idle
  end
  
  def print!(file)
    @starttime = Time.now
    @state = Printer::Printing
    @printing_thread = Thread.new{
      #url = "#{ServerURL}/print_job_positions/#{server_id}.json?percent="
      #system("./printcore.py --json_url #{url} #{@device} #{file}")  
      begin
        puts "Printing thead starting"
        process = IO.popen("./printcore.py -s #{@device} #{file}")  
        oldpct = 0
        while(process.eof == false)
          begin 
             str = process.read_nonblock(65536)
             percent_done = str[-5..-1].gsub("%","").gsub("\b","").to_f
             # only update server when percentage has changed
             if percent_done > oldpct
               oldpct = percent_done
               res = RestClient.get("#{ServerURL}/print_job_positions/#{server_id}.json?percent=#{percent_done}")
             end
           rescue Exception => ex
             if ex.class == EOFError
               break
             end
           end
  
          sleep 10
        end
        @state = Printer::Finished
        puts "Printing thread done!"
    
      rescue Exception => ex
        puts ex
        @state = Printer::Failure
        puts "Printing thread failed!"
      ensure
         # make sure this will be killed!
         pid = process.pid
         system("kill -9 #{pid}")
         process.close
      end       
        
    }
    @state = Printer::Printing
  end
  
  def check_printing_thread
    return if @state != Printer::Printing
    
    if @printing_thread == nil
      @state = Printer::Failure
      puts "Printer #{@uuid} on #{@port} has somehow lost his thread."
      return
    end
    
    if @printing_thread.alive? == false
      @printtime = Time.now - @starttime

      @state = Printer::Finished
      puts "Printer #{@uuid} on #{@port} has finished."
    end   
  end
  
end

def scan_for_printers
  ports = Dir.glob("/dev/ttyACM*") + Dir.glob("/dev/ttyUSB*") 
  @printers.map{|l| ports.delete l.port}
  
  if ports.size > 0
     puts "new device detected, scanning for new printer"
  end
  
  ports.each do |port|   
    if @printers.include? port
      next
    end

    # The raspi kernel oopses on the raspi, crashing the whole USB subsystem. Yay!    

    #s = IO.popen("udevadm info --attribute-walk --name=#{port} |grep {serial}")
    #arduino_id = s.readlines.first.to_s.strip.split("=").last.gsub("\"","")
    
    # okay, this is a shitty workaround, making one raspi able to control one printer
    arduino_id=File.read("arduino_serial").strip
    
    device = ["/dev", port.split("/").last].join("/")
    @printers << Printer.new(port, device, arduino_id)   
  end
end

def get_printer_id(printer)
  if printer.server_id.to_i > 0
    return printer.server_id.to_i    
  end
  
  begin
    res = RestClient.get("#{ServerURL}/machines/0.json?uuid=#{printer.uuid}&port=#{printer.port}")
    if res.dup.to_i <= 0 # maschine nicht erkannt
      puts "Oops. Server doesn't like Printer on #{printer.port} with UUID #{printer.uuid} !"
      printer.state = Printer::Failure
    else
      puts "Printer on #{printer.port} has the ID #{res} on the server"
      printer.server_id = res.dup.to_i
    end
  rescue Exception => ex
     puts "Error while checking UUID with the server: #{ex}"
  end
end

def search_for_job(printer)
  unless printer.server_id.to_i > 0
    puts "drat! Didn't get an id from the server. aborting job search"
    return nil
  end
  begin
    res = RestClient.get("#{ServerURL}/print_jobs/#{printer.server_id}.json")
    if res.strip != ""
      info = JSON.parse(res)
      if info["gcode"] != nil
        # TODO: md5sum, gzip..
        filename = "gcode/#{printer.uuid}"
        f = File.open(filename,"w")
        f.write info["gcode"]
        f.close
        
        # Bulldozer: Check Z height and fix it later.
        r = IO.popen("grep 'Z' #{filename}")
        str = r.readlines.last.to_s.gsub("G1 ","")
        z = str[1..str.index(" ")-1].to_f
        # ugh, this is crappy code
        if z < 60
            
            f = File.open(filename,"w")
            f.write info["gcode"].gsub("M400","G1 Z60 F1000\nM400")
            f.close        
        end
       
        
        puts "got gcode from the server, starting print!"
        printer.print!(filename)
      end
    end
      
  rescue Exception => ex
     puts "Error while checking Print job: #{ex}"
  end
  
  
  
  
end

while(true)
  scan_for_printers
  @printers.each do |printer|
    if printer.state == Printer::Idle
      
      get_printer_id(printer)
      search_for_job(printer)
            
    end
    
    if printer.state == Printer::Printing
      printer.check_printing_thread
    end
    
    if printer.state == Printer::Finished or printer.state == Printer::Failure
      begin
        res = RestClient.get("#{ServerURL}/print_job_positions/#{printer.server_id}.json?state=#{printer.state}&printtime=#{printer.printtime}")
      rescue
      end
      printer.state = Printer::WaitForReactivation      
    end
  
    if printer.state == Printer::WaitForReactivation
      begin
        res = RestClient.get("#{ServerURL}/machines/#{printer.server_id}.json")
        if res.dup.to_i == 1
          printer.state = Printer::Idle  
        end
      rescue
      end
    end
    
  end
  
    
  
  # eventuell ein generelles status-update für alle maschinen?
  sleep 5
end
