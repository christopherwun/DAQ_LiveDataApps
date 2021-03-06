classdef LiveDataApp_6_4 < matlab.apps.AppBase
    %LIVEDATAAPP_6_4 Summary of this class goes here
    %   Detailed explanation goes here
    
    % Properties that correspond to app components
    properties (Access = public)
        UIFigure                       matlab.ui.Figure
        TimewindowEditField            matlab.ui.control.NumericEditField
        TimewindowsEditFieldLabel      matlab.ui.control.Label
        RateSlider                     matlab.ui.control.Slider
        RatescanssSliderLabel          matlab.ui.control.Label
        RateEdit                       matlab.ui.control.NumericEditField
        AcquisitionPanel               matlab.ui.container.Panel
        LogStatusText                  matlab.ui.control.Label
        LogdatatofileSwitch            matlab.ui.control.Switch
        LogdatatofileSwitchLabel       matlab.ui.control.Label
        StopButton                     matlab.ui.control.Button
        StartButton                    matlab.ui.control.Button
    end

    properties (Access = private)
        DAQ                   % Handle to DAQ object
        ChannelDashboards     % Handles to array of channeldashboard objects
        DAQMeasurementTypes = {'Voltage','IEPE','Audio'};  % DAQ input measurement types supported by the app
        DAQSubsystemTypes = {'AnalogInput','AudioInput'};  % DAQ subsystem types supported by the app
        DevicesInfo           % Array of devices that provide analog input voltage or audio input measurements
        LogRequested          % Logical value, indicates whether user selected to log data to file from the UI (set by LogdatatofileSwitch)
        TimestampsFIFOBuffer  % Timestamps FIFO buffer used for live plot of latest "N" seconds of acquired data
        DataFIFOBuffer        % Data FIFO buffer used for live plot of latest "N" seconds of acquired data
        FIFOMaxSize = 1E+6    % Maximum allowed FIFO buffer size for DataFIFOBuffer and TimestampsFIFOBuffer
        TempFilename          % Temporary binary file name, acquired data is logged to this file during acquisition
        TempFile              % Handle of opened binary file, acquired data is logged to this file during acquisition
        Filename = 'daqdata.mat' % Default MAT file name at app start
        Filepath = pwd        % Default folder for saving the MAT file at app start
    end

    
    methods (Access = private)
        
        
        function scansAvailable_Callback(app, src, ~)
        %scansAvailable_Callback Executes on DAQ object ScansAvailable event
        %  This callback function gets executed periodically as more data is acquired.
        %  For a smooth live plot update, it stores the latest N seconds
        %  (specified time window) of acquired data and relative timestamps in FIFO
        %  buffers. A live plot is updated with the data in the FIFO buffer.
        %  If data logging option is selected in the UI, it also writes data to a
        %  binary file.
            
            if ~isvalid(app)
                return
            end
            
            [data,timestamps,triggertime] = read(src, src.ScansAvailableFcnCount, 'OutputFormat','Matrix');
            
            if app.LogRequested
                % If Log data to file switch is on
                latestdata = [timestamps, data]'; 
                fwrite(app.TempFile, latestdata, 'double');
                if timestamps(1)==0
                    app.TriggerTime = triggertime;
                end
            end
            
            % Store continuous acquisition data in FIFO data buffers
            buffersize = round(app.DAQ.Rate * app.TimewindowEditField.Value) + 1;
            app.TimestampsFIFOBuffer = storeDataInFIFO(app, app.TimestampsFIFOBuffer, buffersize, timestamps);
            
            index = 1;
            for cd = app.ChannelDashboards
                cd.DataFIFOBuffer = storeDataInFIFO(app, cd.DataFIFOBuffer, buffersize, data(:,index));
                index = index + 1;
            end
            
            % Update plot data
            for cd = app.ChannelDashboards
                set(cd.LivePlotLine, 'XData', app.TimestampsFIFOBuffer, 'YData', cd.DataFIFOBuffer);
            end

            if numel(app.TimestampsFIFOBuffer) > 1
                xlim(app.LiveAxes, [app.TimestampsFIFOBuffer(1), app.TimestampsFIFOBuffer(end)])
            end
        end
        
        function data = storeDataInFIFO(~, data, buffersize, datablock)
        %storeDataInFIFO Store continuous acquisition data in a FIFO data buffer
        %  Storing data in a finite-size FIFO buffer is used to plot the latest "N" seconds of acquired data for
        %  a smooth live plot update and without continuously increasing memory use.
        %  The most recently acquired data (datablock) is added to the buffer and if the amount of data in the
        %  buffer exceeds the specified buffer size (buffersize) the oldest data is discarded to cap the size of
        %  the data in the buffer to buffersize.
        %  input data is the existing data buffer (column vector Nx1).
        %  buffersize is the desired buffer size (maximum number of rows in data buffer) and can be changed.
        %  datablock is a new data block to be added to the buffer (column vector Kx1).
        %  output data is the updated data buffer (column vector Mx1).
        
            % If the data size is greater than the buffer size, keep only the
            % the latest "buffer size" worth of data
            % This can occur if the buffer size is changed to a lower value during acquisition
            if size(data,1) > buffersize
                data = data(end-buffersize+1:end,:);
            end
            
            if size(datablock,1) < buffersize
                % Data block size (number of rows) is smaller than the buffer size
                if size(data,1) == buffersize
                    % Current data size is already equal to buffer size.
                    % Discard older data and append new data block,
                    % and keep data size equal to buffer size.
                    shiftPosition = size(datablock,1);
                    data = circshift(data,-shiftPosition);
                    data(end-shiftPosition+1:end,:) = datablock;
                elseif (size(data,1) < buffersize) && (size(data,1)+size(datablock,1) > buffersize)
                    % Current data size is less than buffer size and appending the new
                    % data block results in a size greater than the buffer size.
                    data = [data; datablock];
                    shiftPosition = size(data,1) - buffersize;
                    data = circshift(data,-shiftPosition);
                    data(buffersize+1:end, :) = [];
                else
                    % Current data size is less than buffer size and appending the new
                    % data block results in a size smaller than or equal to the buffer size.
                    % (if (size(data,1) < buffersize) && (size(data,1)+size(datablock,1) <= buffersize))
                    data = [data; datablock];
                end
            else
                % Data block size (number of rows) is larger than or equal to buffer size
                data = datablock(end-buffersize+1:end,:);
            end
        end
        
        function [items, itemsData] = getChannelPropertyOptions(~, subsystem, propertyName)
        %getChannelPropertyOptions Get options available for a DAQ channel property
        %  Returns items and itemsData for displaying options in a dropdown component
        %  subsystem is the DAQ subsystem handle corresponding to the DAQ channel
        %  propertyName is channel property name as a character array, and can be
        %    'TerminalConfig', or 'Coupling', or 'Range'.
        %  items is a cell array of possible property values, for example {'DC', 'AC'}
        %  itemsData is [] (empty) for 'TerminalConfig' and 'Coupling', and is a cell array of
        %     available ranges for 'Range', for example {[-10 10], [-1 1]}
            
            switch propertyName
                case 'TerminalConfig'
                    items = cellstr(string(subsystem.TerminalConfigsAvailable));
                    itemsData = [];
                case 'Coupling'
                    items = cellstr(string(subsystem.CouplingsAvailable));
                    itemsData = [];
                case 'Range'
                    numRanges = numel(subsystem.RangesAvailable);
                    items = strings(numRanges,1);
                    itemsData = cell(numRanges,1);
                    for ii = 1:numRanges
                        range = subsystem.RangesAvailable(ii);
                        items(ii) = sprintf('%.2f to %.2f', range.Min, range.Max);
                        itemsData{ii} = [range.Min range.Max];
                    end
                    items = cellstr(items);                    
                case 'ExcitationSource'
                    items = {'Internal','External','None'};
                    itemsData = [];
            end
        end
        
        
        function setAppViewState(app, state)
        %setAppViewState Sets the app in a new state and enables/disables corresponding components
        %  state can be 'deviceselection', 'configuration', 'acquisition', or 'filesave'
        
            switch state                
                case 'deviceselection'
                    app.RateEdit.Enable = 'off';
                    app.RateSlider.Enable = 'off';
                    app.StartButton.Enable = 'off';
                    app.LogdatatofileSwitch.Enable = 'off';
                    app.StopButton.Enable = 'off';
                case 'configuration'
                    app.RateEdit.Enable = 'on';
                    app.RateSlider.Enable = 'on';
                    app.StartButton.Enable = 'on';
                    app.LogdatatofileSwitch.Enable = 'on';
                    app.StopButton.Enable = 'off';
                case 'acquisition'
                    app.RateEdit.Enable = 'off';
                    app.RateSlider.Enable = 'off';
                    app.StartButton.Enable = 'off';
                    app.LogdatatofileSwitch.Enable = 'off';
                    app.StopButton.Enable = 'on';
                    updateLogdatatofileSwitchComponents(app)
                case 'filesave'
                    app.RateEdit.Enable = 'off';
                    app.RateSlider.Enable = 'off';
                    app.StartButton.Enable = 'off';
                    app.LogdatatofileSwitch.Enable = 'off';
                    app.StopButton.Enable = 'off';
                    updateLogdatatofileSwitchComponents(app)   
            end
        end
        
        function binFile2MAT(~, filenameIn, filenameOut, numColumns, metadata)
        %BINFILE2MAT Loads 2-D array of doubles from binary file and saves data to MAT file
        % Processes all data in binary file (filenameIn) and saves it to a MAT file without loading
        % all data to memory.
        % If output MAT file (filenameOut) already exists, data is overwritten (not appended).
        % Input binary file is a matrix of doubles with numRows x numColumns
        % MAT file (filenameOut) is a MAT file with the following variables
        %   timestamps = a column vector ,  the first column in the data from binary file
        %   data = a 2-D array of doubles, includes 2nd-last columns in the data from binary file
        %   metatada = a structure, which is provided as input argument, used to provide additional
        %              data information
        %
            
            % If filenameIn does not exist, error out
            if ~exist(filenameIn, 'file')
                error('Input binary file ''%s'' not found. Specify a different file name.', filenameIn);
            end
            
            % If output MAT file already exists, delete it
            if exist(filenameOut, 'file')
                delete(filenameOut)
            end
            
            % Determine number of rows in the binary file
            % Expecting the number of bytes in the file to be 8*numRows*numColumns
            fileInfo = dir(filenameIn);
            numRows = floor(fileInfo.bytes/(8*double(numColumns)));
            
            % Create matfile object to save data loaded from binary file
            matObj = matfile(filenameOut);
            matObj.Properties.Writable = true;
            
            % Initialize MAT file
            matObj.timestamps(numRows,1) = 0;
            matObj.data(numRows,1:numColumns) = 0;
            
            % Open input binary file
            fid = fopen(filenameIn,'r');
            
            % Specify how many rows to process(load and save) at a time
            numRowsPerChunk = 10E+6;
            
            % Keeps track of how many rows have been processed so far
            ii = 0;
            
            while(ii < numRows)
                
                % chunkSize = how many rows to process in this iteration
                % If it's the last iteration, it's possible the number of rows left to
                % process is different from the specified numRowsPerChunk
                chunkSize = min(numRowsPerChunk, numRows-ii);
                
                data = fread(fid, [numColumns,chunkSize], 'double');
                
                matObj.timestamps((ii+1):(ii+chunkSize), 1) = data(1,:)';
                matObj.data((ii+1):(ii+chunkSize), 1:numColumns) = data(2:end,:)';

                ii = ii + chunkSize;
            end
            
            fclose(fid);
            
            % Save provided metadata to MAT file
            matObj.metadata = metadata;
        end
        
        function updateRateUIComponents(app)
        %updateRateUIComponents Updates UI with current rate and time window limits
            
            % Update UI to show the actual data acquisition rate and limits
            value = app.DAQ.Rate;
            app.RateEdit.Limits = app.DAQ.RateLimit;
            app.RateSlider.Limits = app.DAQ.RateLimit;
            app.RateSlider.MajorTicks = [app.DAQ.RateLimit(1) app.DAQ.RateLimit(2)];
            app.RateSlider.MinorTicks = [];
            app.RateEdit.Value = value;
            app.RateSlider.Value = value;
            
            % Update time window limits
            % Minimum time window shows 2 samples
            % Maximum time window corresponds to the maximum specified FIFO buffer size
            minTimeWindow = 1/value;
            maxTimeWindow = app.FIFOMaxSize / value;
            app.TimewindowEditField.Limits = [minTimeWindow, maxTimeWindow];
            
        end
        
        
        function closeApp_Callback(app, ~, event, isAcquiring)
        %closeApp_Callback Clean-up after "Close Confirm" dialog window
        %  "Close Confirm" dialog window is called from CloseRequestFcn
        %  of the app UIFigure.
        %   event is the event data of the UIFigure CloseRequestFcn callback.
        %   isAcquiring is a logical flag (true/false) corresponding to DAQ
        %   running state.            
            
            %   Before closing app if acquisition is currently on (isAcquiring=true) clean-up 
            %   data acquisition object and close file if logging.
            switch event.SelectedOption
                case 'OK'
                    if isAcquiring
                        % Acquisition is currently on
                        stop(app.DAQ)
                        delete(app.DAQ)
                        if app.LogRequested
                            fclose(app.TempFile);
                        end
                    else
                        % Acquisition is stopped
                    end

                    delete(app)
                case 'Cancel'
                    % Continue
            end
            
        end
        
        
        function updateDAQ(app, cd)
        %updateChannelMeasurementComponents Updates channel properties and measurement UI components
            % Get selected DAQ device index (to be used with DaqDevicesInfo list)
            deviceIndex = cd.DeviceDropDown.Value - 1;
            vendor = cd.DevicesInfo(deviceIndex).Vendor.ID;
            
            % Delete existing data acquisition object
            delete(app.DAQ);
            app.DAQ = [];
            
            % Create a new data acquisition object
            d = daq(vendor);
            for channel = app.ChannelDashboards
                deviceIndex = channel.DeviceDropDown.Value - 1;
                deviceID = channel.DevicesInfo(deviceIndex).ID;
                addinput(d, deviceID, channel.ChannelDropDown.Value, channel.MeasurementTypeDropdown.Value)
            end
         
            % Configure DAQ ScansAvailableFcn callback function
            d.ScansAvailableFcn = @(src,event) scansAvailable_Callback(app, src, event);
            
            % Store data acquisition object handle in DAQ app property
            app.DAQ = d;

            updateChannelMeasurementComponents(cd)             
                        
            % Update UI with current rate and time window limits
            updateRateUIComponents(app)
            
            % Enable DAQ device, channel properties, and start acquisition UI components
            setAppViewState(app, 'configuration');
        end
        
        function updateLogdatatofileSwitchComponents(app)
            value = app.LogdatatofileSwitch.Value;
            switch value
                case 'Off'
                    app.LogRequested = false;
                case 'On'
                    app.LogRequested = true;
            end
        end
    end

    % Callbacks that handle component events
    methods (Access = private)

        % Code that executes after component creation
        function startupFcn(app)
            
            % This function executes when the app starts, before user interacts with UI
            
            % Set the app controls in device selection state
            setAppViewState(app, 'deviceselection');
            drawnow
            
            app.ChannelDashboards = {};
            app.ChannelDashboards = [app.ChannelDashboards, ChannelDashboard()];

        end
       
        % Button pushed function: StartButton
        function StartButtonPushed(app, event)
                               
            % Disable DAQ device, channel properties, and start acquisition UI components
            setAppViewState(app, 'acquisition');               
            
            if app.LogRequested
                % If Log data to file switch is on
                % Create and open temporary binary file to log data to disk
                app.TempFilename = tempname;
                app.TempFile = fopen(app.TempFilename, 'w');
            end
            
            % Reset FIFO buffer data
            for cd = app.ChannelDashboards
                cd.DataFIFOBuffer = [];
                cd.TimestampsFIFOBuffer = [];
            end
            
            try
                start(app.DAQ,'continuous');
            catch exception
                % In case of error show it and revert the change
                uialert(app.LiveDataAcquisitionUIFigure, exception.message, 'Start error');   
                setAppViewState(app, 'configuration'); 
            end
            
            % Clear Log status text
            app.LogStatusText.Text = '';

        end

        % Button pushed function: StopButton
        function StopButtonPushed(app, event)

            setAppViewState(app, 'filesave');
            stop(app.DAQ);

            if app.LogRequested
                % Log data to file switch is on
                % Save logged data to MAT file (unless the user clicks Cancel in the "Save As" dialog)
                
                % Close temporary binary file
                fclose(app.TempFile);
                
                
                % Gather metadata in preparation for saving to MAT file
                % Store relevant Daq device info
                
                    deviceInfo = get(app.DevicesInfo(app.DeviceDropDown.Value-1));
                    deviceInfo.Vendor = get(deviceInfo.Vendor);
                    deviceInfo = rmfield(deviceInfo, 'Subsystems');
                    metadata.DeviceInfo = deviceInfo;
                    metadata.Channel1 = app.Channel1DropDown.Value;
                    metadata.Channel2 = app.Channel2DropDown.Value;
                    metadata.MeasurementType = app.MeasurementTypeDropDown.Value;
                    metadata.Range = app.RangeDropDown.Value;
                    metadata.Coupling = app.CouplingDropDown.Value;
                    metadata.TerminalConfig = app.TerminalConfigDropDown.Value;
                    metadata.ExcitationSource = app.ExcitationSourceDropDown.Value;
                    metadata.Rate = app.RateEdit.Value;
                    metadata.TriggerTime = datetime(app.TriggerTime, 'ConvertFrom', 'datenum', 'TimeZone', 'local');
                
                % Open "Save As" to request destination MAT file path and file name from user
                [filename, pathname] = uiputfile({'*.mat'}, 'Save as',...
                    fullfile(app.Filepath, app.Filename));
                
                if ~(isequal(filename,0) || isequal(pathname,0))
                    % User specified a file name in a folder with write permission
                    app.Filename = filename;
                    app.Filepath = pathname;
                    cancelSaveAs = false;
                else
                    %  User clicked Cancel in "Save As" dialog
                    cancelSaveAs = true;
                end
                
                if ~cancelSaveAs
                    % Convert data from binary file to MAT file
                    matFilepath = fullfile(app.Filepath, app.Filename);
                    app.LogStatusText.Text = 'Saving data to MAT file is in progress...';
                    drawnow
                    
                    numColumns = 3;
                    binFile2MAT(app, app.TempFilename, matFilepath, numColumns, metadata);
                    app.LogStatusText.Text = sprintf('Saving data to ''%s'' file has completed.', app.Filename);
                    
                else
                    % User clicked Cancel in "Save As" dialog
                    % Inform user that data has not been saved
                    app.LogStatusText.Text = 'Saving data to MAT file was cancelled.';
                end
            end
            
            % Enable DAQ device, channel properties, and start acquisition UI components
            setAppViewState(app, 'configuration');
        end

        % Value changed function: Channel1DropDown
        function Channel1DropDownValueChanged(app, event)
            
            updateChannelMeasurementComponents(app)
            
        end

        % Value changed function: Channel1DropDown
        function Channel2DropDownValueChanged(app, event)
            
            updateChannelMeasurementComponents(app)
            
        end

        % Value changed function: CouplingDropDown, 
        % ...and 3 other components
        function ChannelPropertyValueChanged(app, event)
            % Shared callback for RangeDropDown, TerminalConfigDropDown, CouplingDropDown, and ExcitationSourceDropDown
            
            % This executes only for 'Voltage' measurement type, since for 'Audio' measurement
            % type Range never changes, and TerminalConfig and Coupling are disabled.
            
            value = event.Source.Value;
            
            % Set channel property to selected value
            % The channel property name was previously stored in the UI component Tag
            propertyName = event.Source.Tag;
            try
                set(app.DAQ.Channels(1), propertyName, value);
            catch exception
                % In case of error show it and revert the change
                uialert(app.LiveDataAcquisitionUIFigure, exception.message, 'Channel property error');
                event.Source.Value = event.PreviousValue;
            end
            
            % Make sure shown channel property values are not stale, as some property update can trigger changes in other properties
            % Update UI with current channel property values from data acquisition object
            currentRange = app.DAQ.Channels(1).Range;
            app.RangeDropDown.Value = [currentRange.Min currentRange.Max];
            app.TerminalConfigDropDown.Value = app.DAQ.Channels(1).TerminalConfig;
            app.CouplingDropDown.Value = app.DAQ.Channels(1).Coupling;
            
        end

        % Value changing function: RateSlider
        function RateSliderValueChanging(app, event)
            changingValue = event.Value;
            app.RateEdit.Value = changingValue;
        end

        % Value changed function: RateEdit, RateSlider
        function RateSliderValueChanged(app, event)
            % Shared callback for RateSlider and RateEdit
            
            value = event.Source.Value;
            if ~isempty(app.DAQ)
                app.DAQ.Rate = value;
                
                % Update UI with current rate and time window limits
                updateRateUIComponents(app)
                
            end
        end

        % Value changed function: YmaxEditField, YminEditField
        function YmaxminValueChanged(app, event)
            % Shared callback for YmaxEditField and YminEditField
            
            ymin = app.YminEditField.Value;
            ymax = app.YmaxEditField.Value;
            if ymax>ymin
                ylim(app.LiveAxes, [ymin, ymax]);
            else
                % If new limits are not correct, revert the change
                event.Source.Value = event.PreviousValue;
            end
        end

        % Value changed function: AutoscaleYSwitch
        function AutoscaleYSwitchValueChanged(app, event)
            updateAutoscaleYSwitchComponents(app)
        end

        % Value changed function: LogdatatofileSwitch
        function LogdatatofileSwitchValueChanged(app, event)
            updateLogdatatofileSwitchComponents(app)
        end

        % Close request function: LiveDataAcquisitionUIFigure
        function LiveDataAcquisitionCloseRequest(app, event)
            
            isAcquiring = ~isempty(app.DAQ) && app.DAQ.Running;
            if isAcquiring
                question = 'Abort acquisition and close app?';
                
            else
                % Acquisition is stopped
                question = 'Close app?';
            end
            
            uiconfirm(app.LiveDataAcquisitionUIFigure,question,'Confirm Close',...
                'CloseFcn',@(src,event) closeApp_Callback(app,src,event,isAcquiring));
            
        end

        % Value changed function: MeasurementTypeDropDown
        function MeasurementTypeDropDownValueChanged(app, event)
            
            updateChannelMeasurementComponents(app)

        end
    end

    % Component initialization
    methods (Access = private)

        % Create UIFigure and components
        function createComponents(app)
            % Create UIFigure and hide until all components are created
            app.UIFigure = uifigure('Visible', 'off');
            app.UIFigure.Position = [100 100 908 602];
            app.UIFigure.Name = 'Live Data Acquisition';

            % Create AcquisitionPanel
            app.AcquisitionPanel = uipanel(app.UIFigure);
            app.AcquisitionPanel.Position = [282 498 613 89];

            % Create StartButton
            app.NewChannelButton = uibutton(app.AcquisitionPanel, 'push');
            app.NewChannelButton.ButtonPushedFcn = createCallbackFcn(app, @StartButtonPushed, true);
            app.NewChannelButton.BackgroundColor = [0.4706 0.6706 0.1882];
            app.NewChannelButton.FontSize = 14;
            app.NewChannelButton.FontColor = [1 1 1];
            app.NewChannelButton.Position = [341 32 100 24];
            app.NewChannelButton.Text = 'New Channel';

            % Create StartButton
            app.StartButton = uibutton(app.AcquisitionPanel, 'push');
            app.StartButton.ButtonPushedFcn = createCallbackFcn(app, @StartButtonPushed, true);
            app.StartButton.BackgroundColor = [0.4706 0.6706 0.1882];
            app.StartButton.FontSize = 14;
            app.StartButton.FontColor = [1 1 1];
            app.StartButton.Position = [341 32 100 24];
            app.StartButton.Text = 'Start';

            % Create StopButton
            app.StopButton = uibutton(app.AcquisitionPanel, 'push');
            app.StopButton.ButtonPushedFcn = createCallbackFcn(app, @StopButtonPushed, true);
            app.StopButton.BackgroundColor = [0.6392 0.0784 0.1804];
            app.StopButton.FontSize = 14;
            app.StopButton.FontColor = [1 1 1];
            app.StopButton.Position = [462 32 100 24];
            app.StopButton.Text = 'Stop';

            % Create TimewindowsEditFieldLabel
            app.TimewindowsEditFieldLabel = uilabel(app.LiveViewPanel);
            app.TimewindowsEditFieldLabel.HorizontalAlignment = 'right';
            app.TimewindowsEditFieldLabel.Position = [444 440 92 22];
            app.TimewindowsEditFieldLabel.Text = 'Time window (s)';

            % Create TimewindowEditField
            app.TimewindowEditField = uieditfield(app.LiveViewPanel, 'numeric');
            app.TimewindowEditField.Position = [540 440 56 22];
            app.TimewindowEditField.Value = 1;

            % Create LogdatatofileSwitchLabel
            app.LogdatatofileSwitchLabel = uilabel(app.AcquisitionPanel);
            app.LogdatatofileSwitchLabel.HorizontalAlignment = 'center';
            app.LogdatatofileSwitchLabel.Position = [50 33 84 22];
            app.LogdatatofileSwitchLabel.Text = 'Log data to file';

            % Create LogdatatofileSwitch
            app.LogdatatofileSwitch = uiswitch(app.AcquisitionPanel, 'slider');
            app.LogdatatofileSwitch.ValueChangedFcn = createCallbackFcn(app, @LogdatatofileSwitchValueChanged, true);
            app.LogdatatofileSwitch.Position = [165 34 45 20];

            % Create LogStatusText
            app.LogStatusText = uilabel(app.AcquisitionPanel);
            app.LogStatusText.Position = [54 6 532 22];
            app.LogStatusText.Text = '';

            % Create RateEdit
            app.RateEdit = uieditfield(app.UIFigure, 'numeric');
            app.RateEdit.Limits = [1e-06 10000000];
            app.RateEdit.ValueDisplayFormat = '%.1f';
            app.RateEdit.ValueChangedFcn = createCallbackFcn(app, @RateSliderValueChanged, true);
            app.RateEdit.Position = [123 106 100 22];
            app.RateEdit.Value = 1000;

            % Create RatescanssSliderLabel
            app.RatescanssSliderLabel = uilabel(app.UIFigure);
            app.RatescanssSliderLabel.HorizontalAlignment = 'right';
            app.RatescanssSliderLabel.Position = [28 106 83 22];
            app.RatescanssSliderLabel.Text = 'Rate (scans/s)';

            % Create RateSlider
            app.RateSlider = uislider(app.UIFigure);
            app.RateSlider.Limits = [1e-06 1000];
            app.RateSlider.ValueChangedFcn = createCallbackFcn(app, @RateSliderValueChanged, true);
            app.RateSlider.ValueChangingFcn = createCallbackFcn(app, @RateSliderValueChanging, true);
            app.RateSlider.Position = [71 95 150 3];
            app.RateSlider.Value = 1000;

            app.UIFigure.Visible = 'on';
        end

    end

    % App creation and deletion
    methods (Access = public)

        % Construct app
        function app = LiveDataApp_6_4

            % Create components
            createComponents(app)

            % Execute the startup function
            runStartupFcn(app, @startupFcn)

            if nargout == 0
                clear app
            end
        end

        % Code that executes before app deletion
        function delete(app)

            % Delete UIFigure when app is deleted
            delete(app.UIFigure)
        end
    end
end

