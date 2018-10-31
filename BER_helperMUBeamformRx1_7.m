%% Clear environment
clear all; clear classes; close all; clc;

%% Configuration
elevList     = (90:-10:0);
azymList     = 90;
angleDur     = 20;
margin       = 0;
maxIter      = 10000;
maxIterRot   = length(elevList)*length(azymList)*angleDur + margin;
modList      = [64 32 16 8 4 2];
nTxAntennas1 = 2;
nTxAntennas2 = 0;
nTxAntennas  = nTxAntennas1 + nTxAntennas2;
gain         = 30;
NFFT         = 256;

%% Configure radios

% Load radio configuration from a file
load(fullfile('data','radioConfig.mat'));
radioConfig.rxID1 = '30BC5C4';  % Force to use the second B210
% Load Transmitted bits for the modulations used
load(fullfile('data','information4.mat'),'bits');
% Load pre-defined Gold sequences
load('data/trainingSig.mat','trainingSig');

% Connect to radio
receiver = comm.SDRuReceiver('Platform',radioConfig.rxPlatform1,...
                             radioConfig.rxIDProp1,radioConfig.rxID1,...
                             'MasterClockRate',radioConfig.rxMasterClockRate1,...
                             'DecimationFactor',radioConfig.rxDecimationfactor1,...
                             'ClockSource','External',...
                             'Gain',gain,...
                             'CenterFrequency',900e6,...
                             'EnableBurstMode',true,...
                             'SamplesPerFrame',200e3,...
                             'OutputDataType','double',...
                             'NumFramesInBurst',0);




% Variable to store the BER
BER = zeros(maxIter,length(modList));

% Open temporary file for writing channel estimate
fileName = 'helperMUBeamformfeedback1.bin';
fid = fopen(fileName,'wb');

% Random initial channel
% chEst_old = rand(1,nTxAntennas) + 1j*rand(1,nTxAntennas);
chEst_old = zeros(1,nTxAntennas) + 1j*zeros(1,nTxAntennas);
rxPow_old = 0;

% Create Angle List
elevList1 = repelem(elevList,1,length(azymList));
azymList1 = repmat(azymList,1,length(elevList));
elevList1 = repelem(elevList1,1,angleDur);
azymList1 = repelem(azymList1,1,angleDur);
elevList1 = [90.*ones(1,margin) elevList1];
azymList1 = [90.*ones(1,margin) azymList1];
elev_old = elevList1(1);
azym_old = azymList1(1);

%% Main loopif nargin == 2

tic;
chTot = zeros(nTxAntennas,maxIter);
iterRot = 1;
for i = 1:maxIter
    tic;
    [rxSig, len] = receiver();
    toc;
    if len > 0
        [chEst, payload_rx, finalCorrectionTime] = ...
            BER_helperMUBeamformEstimateChannel_2(rxSig, trainingSig, nTxAntennas1, nTxAntennas2);
        fftOut = fft(reshape(payload_rx, NFFT, 64));
        
        if finalCorrectionTime>48340
            countCorr = 1;
            finalCorrectionTime = [0 0];
            fprintf('System needs to be corrected by %d and %d samples\n',finalCorrectionTime);
        elseif finalCorrectionTime>0
            fprintf('System needs to be corrected by %d and %d samples\n',finalCorrectionTime);
        end
        
        for modIdx = 1:length(modList)
            index = 4 + modIdx;
            y = fftOut(index,:).';  % Extract Subcarrier
            y = y/sqrt(mean(y'*y));  % Normalize symbols
            y = 1/sqrt(sum(var(y))).*y;  % Normalize symbols
%             % Plot conste\nllation
%             figure(modIdx); clf('reset');
%             figure(modIdx); hold on;
%             y_tx = qammod(bits{modIdx},modList(modIdx),'InputType','bit','UnitAveragePower',true);
%             plot(real(y_tx),imag(y_tx),'LineStyle','None','Marker','.','Color','r');
%             plot(real(y),imag(y),'LineStyle','None','Marker','.','Color','b');
%             xlim([-2 2]);  ylim([-2 2]);  % Normalized
%             tit = strcat('Receiver with k =',{' '},num2str(modList(modIdx)));
%             title(tit{1},'FontSize',12);
            % Compute Bit Error Rate for the 64-QAM modulation
            if ~isempty(y) && ~any(isnan(y))
                    % Demodulator expecting normalized symbols
                    M = modList(modIdx);
                    data_rx = qamdemod(y,M,'OutputType','bit','UnitAveragePower',true);
                    % Compute BER
                    BER(i,modIdx) = sum(abs(bits{modIdx} - data_rx))/length(data_rx);
                    fprintf('Iter %d - BER: %.3f\n',i,BER(i,modIdx));
            elseif i>1
                BER(i,modIdx) = BER(i-1,modIdx);  % First element is the BER
                fprintf('Iter %d - BER: %.3f (Hardcoded)\n',i,BER(i,modIdx));
            else
                BER(i,modIdx) = 0.5;  % Assigning random value
                fprintf('Iter %d - BER: %.3f (Hardcoded - Random)\n',i,BER(i,modIdx));
            end
        end
        
        % Write channel estimate to a file
        fseek(fid,0,'bof');
        if ~any(isnan(chEst)) && length(chEst)==nTxAntennas
            % Write to file and transmit to TX-hosts using Python
            fwrite(fid,[real(chEst(1:nTxAntennas1)) imag(chEst(1:nTxAntennas1)) ...  % 1st TX
                        finalCorrectionTime(1) ...   % Correction time for 1st TX
                        elevList1(iterRot) ...  % Elevation angle for 1st TX
                        azymList1(iterRot) ...  % Azymuth angle for 1st TX
                        elevList1(iterRot) ...  % Elevation angle for 1st TX
                        azymList1(iterRot) ...  % Azymuth angle for 1st TX
                        real(chEst(nTxAntennas1+1:nTxAntennas)) imag(chEst(nTxAntennas1+1:nTxAntennas)) ... % 2nd TX
                        finalCorrectionTime(2) ...  % Correction time for 2 TX
                        elevList1(iterRot) ...  % Elevation angle for 2nd TX
                        azymList1(iterRot) ...  % Azymuth angle for 1st TX
                        elevList1(iterRot) ...  % Elevation angle for 1st TX
                        azymList1(iterRot) ...  % Azymuth angle for 1st TX
                        ],'double'); ...  % Azymuth angle for 2nd TX
            % Store applied angles
            appliedElev(i) = elevList1(iterRot);
            elev_old = elevList1(iterRot);
            appliedAzym(i) = azymList1(iterRot);
            azym_old = azymList1(iterRot);
            % Compute BER
            % Store channel estimation
            chTot(:,i) = chEst;
            chEst_old = chEst;
            rxPow(i) = pow2db((payload_rx'*payload_rx)/length(payload_rx)) + 30;
            rxPow_old = rxPow(i);
            % Print out the estimation
            fprintf('Iter %d:\n',i);
            for id = 1:nTxAntennas1
                fprintf('h1(%d) = %.7f + %.7fj\n',id,real(chEst(id)),imag(chEst(id)));
                fprintf('elev = %.2f\n',elevList1(iterRot));
                fprintf('azym = %.2f\n',azymList1(iterRot));
            end
            for id = nTxAntennas1+1:nTxAntennas
                fprintf('h2(%d) = %.7f + %.7fj\n',id,real(chEst(id)),imag(chEst(id)));
                fprintf('elev = %.2f\n',elevList1(iterRot));
                fprintf('azym = %.2f\n',azymList1(iterRot));
            end
            fprintf('Rx Power (dBm) = %.3f\n',rxPow(i));
            % Stop execution when reached the maximum number of angles
            if iterRot == maxIterRot
                break;
            else
                iterRot = iterRot + 1;
            end
        else
            % Store estimation in global variable
            chTot(:,i) = chEst_old;
            rxPow(i) = rxPow_old;
            appliedElev(i) = elev_old;
            appliedAzym(i) = azym_old;
        end
    else
        chTot(:,i) = chEst_old;
        rxPow(i) = rxPow_old;
        appliedElev(i) = elev_old;
        appliedAzym(i) = azym_old;
    end
    
    figure(2);
%     cla reset; hold on;
    for idxFFT = 1:nTxAntennas
        subplot(1,nTxAntennas,idxFFT); hold on;
        plot((1:i),abs(chTot(idxFFT,1:i)),'Color','r','LineWidth',2,'Marker','s','MarkerSize',2);
        title('Absolute Gain','FontSize',12);
        xlabel('Iteration','FontSize',12);
        ylabel('Gain','FontSize',12);
    end
end

save('sim_BER-exp2ant.mat');

lastIter = i;
for idxFFT = 1:nTxAntennas
    figure(15);
    subplot(nTxAntennas,3,3*(idxFFT-1) + 1); hold on; grid minor;
    % plot((1:maxIter),real(chRealTot),'Color','b');
    plot((1:lastIter),real(chTot(idxFFT,1:lastIter)),'Color','r','LineWidth',2);
    title('Real','FontSize',12);
    xlabel('Iteration','FontSize',12);
    ylabel('Gain','FontSize',12);
    subplot(nTxAntennas,3,3*(idxFFT-1) + 2); hold on; grid minor;
    % plot((1:maxIter),imag(chRealTot),'Color','b');
    plot((1:lastIter),imag(chTot(idxFFT,1:lastIter)),'Color','r','LineWidth',2);
    title('Imaginary','FontSize',12);
    xlabel('Iteration','FontSize',12);
    ylabel('Gain','FontSize',12);
    subplot(nTxAntennas,3,3*(idxFFT-1) + 3); hold on; grid minor;
    plot((1:lastIter),abs(chTot(idxFFT,1:lastIter)),'Color','r','LineWidth',2);
    title('Absolute Gain','FontSize',12);
    xlabel('Iteration','FontSize',12);
    ylabel('Gain','FontSize',12);

    figure(16);
    subplot(4,1,idxFFT); hold on;
    covTot_imag = zeros(lastIter,1);
    covTot_real = zeros(lastIter,1);
    re = real(chTot(idxFFT,:));
    im = imag(chTot(idxFFT,:));
    re(isnan(re))=0;
    window_size = 1;
    for k = 1:1:lastIter-window_size
        covTot_imag(k) = cov(im(k:k+window_size));
        covTot_real(k) = cov(re(k:k+window_size));
    end
    plot(abs(1-covTot_imag),'LineWidth',2);
    plot(abs(1-covTot_real),'LineWidth',2);
    legend('Imaginary','Real');
    ylim([0.999 1]);
end

figure(17);
totGain = 0;
for txID = 1:nTxAntennas
    t = abs(chTot(txID,1:lastIter));
    t(isnan(t))=0;  % replace nan values
    totGain = totGain + t;
end
 plot((1:lastIter),totGain,'Color','r','LineWidth',2);
title('Total channel Gain','FontSize',12);
xlabel('Iteration','FontSize',12);
ylabel('Gain (linear)','FontSize',12);

figure(18);
subplot(611); plot(abs(BER(1:i,1)),'LineWidth',1.5); legend('64-QAM'); ylabel('BER'); ylim([0 1]);
subplot(612); plot(abs(BER(1:i,2)),'LineWidth',1.5); legend('32-QAM'); ylabel('BER'); ylim([0 1]);
subplot(613); plot(abs(BER(1:i,3)),'LineWidth',1.5); legend('16-QAM'); ylabel('BER'); ylim([0 1]);
subplot(614); plot(abs(BER(1:i,4)),'LineWidth',1.5); legend('8-QAM'); ylabel('BER'); ylim([0 1]);
subplot(615); plot(abs(BER(1:i,5)),'LineWidth',1.5); legend('QPSK'); ylabel('BER'); ylim([0 1]);
subplot(616); plot(abs(BER(1:i,6)),'LineWidth',1.5); legend('BPSK'); ylabel('BER'); ylim([0 1]);

release(receiver);

%% Appendix
% This example uses the following helper functions:
%
% * <matlab:edit('helperMUBeamformInitGoldSeq.m') helperMUBeamformInitGoldSeq.m>
% * <matlab:edit('helperMUBeamformEstimateChannel.m') helperMUBeamformEstimateChannel.m>

%% Copyright Notice
% Universal Software Radio Peripheral(R) and USRP(R) are trademarks of
% National Instruments Corp.