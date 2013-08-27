/*
 * Copyright (c) 2013, AllWorldIT
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 *
 *
 * Author: Charl Mert <cmert@lbsd.net>, 2013
 *
 */

(function ($) {
	var options = {
		debug :true
	};

	var socket = null;
	var buffer = [];

	function log_error(message) 
	{
		if (typeof(console.error) != 'undefined' && options.debug) {
			console.error(message);
		}
	}

	function log_info(message) 
	{
		if (typeof(console.info) != 'undefined' && options.debug) {
			console.info(message);
		}
	}

	function log(message) 
	{
		if (typeof(console.log) != 'undefined' && options.debug) {
			console.log(message);
		}
	}

	// Expecting column data format: [yyyy-mm-dd hh-mm-ss, value]
	function addColumn(column, options) 
	{
		// Converting timestamps

		// Creating dataset
		changed = [];

		jQuery.each(column, function(key, val) {
		
			columnData = statsData[key];
			
			if (typeof(columnData) == 'undefined') {
				// Creating new field
				statsData[key] = {
					label: key,
					data: [new Date(val[0].replace(/-/g, '/')).getTime(), val[1]]
				};

				changed.push(statsData[key]);

			} else {
				// Appending existing field
				columnData = statsData[key];
				if (columnData.data.length >= options.websocket.maxTicksX) {
					columnData.data.shift();
				}
				columnData.data.push([new Date(val[0].replace(/-/g, '/')).getTime(), val[1]]);
				changed.push(statsData[key]);
			}
		});

		//console.log(JSON.stringify(changed));
		return changed;
	}

	// update the chart to reflect the new column
	function updateChart(plot, options, column) {
		// add column
		chartData = addColumn(column, options);

		if (plot) {
			jQuery.plot(plot.getPlaceholder(), chartData, options);
		} else {
			log_error('Plot object not initialized');
		}
	}

	// connect websocket
	function connectWebsocket(uri) {

		try {
			log('Connecting...: ' + uri);
			socket = window['MozWebSocket'] ? new MozWebSocket(uri) : new WebSocket(uri);
			return socket;
		} catch (e) {
			log_error('Sorry, the web socket at ' + uri + ' is un-available (' + e + ')', uri, e);
		}
	}

	function init(plot) {
		plot.hooks.processOptions.push(function (plot, options) {
			if (typeof(options.websocket) != 'undefined') {

				if (options.websocket.enabled == false) {
					return false;
				}

				if (typeof(options.websocket.maxTicksX) == 'undefined') {
					options.websocket.maxTicksX = 20;
				}

				uri = options.websocket.uri;

				if (socket == null) {
					socket = connectWebsocket(uri);
				}

				// When the connection is open, send some data to the server
				socket.onopen = function () {
					log('Sending Hello ... ');
					log('Socket State: ['+socket.readyState+']');
					if (socket && socket.readyState == 1) {
						socket.send('Ping'); // Send the message to the server
					} else {
						log_error("Couldn't send Ping!");
					}
				};

				// Log errors
				socket.onerror = function (error) {
					log('WebSocket Error:');
					log(error);
				};

				// Log messages from the server
				socket.onmessage = function (e) {
					try {
						column = JSON.parse(e.data);
						updateChart(plot, options, column);
					} catch (err) {
						//couldn't parse json
						log('Exception: ' + e);
						log(e);
					}
				};

			} else {
				log('Websocket options not specified');
			}
		});
	}

	$.plot.plugins.push({
		init: init,
		options: options,
		name: 'websockets',
		version: '1.0'
	});
})(jQuery);
