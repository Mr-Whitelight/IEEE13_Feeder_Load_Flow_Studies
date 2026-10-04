%% BESS Mitigation Sweep — bus 634 (handle-matched detection)
% Robust: identifies each block by matching Simulink handles

%% === Clean up ===
clc;
clear;
close all;

% === Configuration ===
model      = 'IEEE13NodeTestFeeder';
V_limit    = 1.07;
V_lower    = 0.95;
der_levels = [0, 500, 1000, 1500, 2000, 2500, 3000, 3500, 4000];   % kW

% BESS ratings: [P_kW, Q_kvar]
BESS_ratings = [
    300, 300;
    500, 500;
    800, 500;
];
rating_labels = {'BESS 300kW/300kvar', 'BESS 500kW/500kvar', 'BESS 800kW/500kvar'};

% === Reload workspace ===
fprintf('Loading init script...\n');
run('IEEE13NodeTestFeederInit');
load_system(model);

%% === HANDLE-BASED CELL DETECTION ===
LF_probe = power_loadflow(model, 'parameters');

% Get the Simulink handle for each block
handle_der  = get_param([model '/DER_634'],      'Handle');
handle_dst  = get_param([model '/DSTATCOM_634'], 'Handle');
handle_bess = get_param([model '/BESS_634'],     'Handle');

fprintf('Simulink handles: DER=%.4f | DSTATCOM=%.4f | BESS=%.4f\n', ...
    handle_der, handle_dst, handle_bess);

% Match against pqload cells
cell_der = []; cell_dst = []; cell_bess = [];
for c = 1:length(LF_probe.pqload(1).handle)
    h = LF_probe.pqload(1).handle{c};
    if iscell(h), h = h{1}; end
    if abs(h - handle_der)  < 0.01, cell_der  = c; end
    if abs(h - handle_dst)  < 0.01, cell_dst  = c; end
    if abs(h - handle_bess) < 0.01, cell_bess = c; end
end

fprintf('Matched: DER→cell %d | DSTATCOM→cell %d | BESS→cell %d\n', ...
    cell_der, cell_dst, cell_bess);

if isempty(cell_der) || isempty(cell_dst) || isempty(cell_bess)
    error('Failed to match one or more blocks to pqload cells.');
end

%% === Sweep for each BESS rating (DSTATCOM OFF) ===
n   = length(der_levels);
n_b = size(BESS_ratings, 1);

Vmax_bess = zeros(n, n_b);
Vmin_bess = zeros(n, n_b);
SlackP_bess = zeros(n, n_b);

for b = 1:n_b
    P_bess = BESS_ratings(b, 1) * 1000;   % W (positive = charge)
    Q_bess = BESS_ratings(b, 2) * 1000;   % var (positive = absorb)
    
    fprintf('\n=== %s ===\n', rating_labels{b});
    
    for k = 1:n
        LF = power_loadflow(model, 'parameters');
        
        for c = 1:length(LF.pqload(1).P)
            LF.pqload(1).P{c} = 0;
            LF.pqload(1).Q{c} = 0;
        end
        
        % DER injection (negative = generation)
        LF.pqload(1).P{cell_der} = -der_levels(k) * 1000;
        LF.pqload(1).Q{cell_der} = 0;
        
        % DSTATCOM OFF
        LF.pqload(1).P{cell_dst} = 0;
        LF.pqload(1).Q{cell_dst} = 0;
        
        % BESS ON
        LF.pqload(1).P{cell_bess} = P_bess;
        LF.pqload(1).Q{cell_bess} = Q_bess;
        
        try
            LF_sol = power_loadflow(model, 'solve', LF);
        catch ME
            fprintf('  ERROR at %d kW: %s\n', der_levels(k), ME.message);
            continue;
        end
        
        % Extract voltages
        Vmag = [];
        for i = 1:length(LF_sol.vsrc)
            if ~isempty(LF_sol.vsrc(i).Vt)
                Vmag = [Vmag; abs(LF_sol.vsrc(i).Vt{1}(:))];
            end
        end
        for i = 1:length(LF_sol.rlcload(1).Vt)
            V = abs(LF_sol.rlcload(1).Vt{i}(:));
            V = V(abs(V-1) > 1e-4);
            Vmag = [Vmag; V];
        end
        for i = 1:length(LF_sol.pqload(1).Vt)
            V = abs(LF_sol.pqload(1).Vt{i}(:));
            V = V(abs(V-1) > 1e-4);
            Vmag = [Vmag; V];
        end
        
        Vmax_bess(k, b)   = max(Vmag);
        Vmin_bess(k, b)   = min(Vmag);
        SlackP_bess(k, b) = sum(real(LF_sol.vsrc(1).S{1})) * LF_sol.basePower / 1e3;
        
        fprintf('  DER=%4d kW | Vmax=%.4f | Vmin=%.4f | SlackP=%.1f kW\n', ...
            der_levels(k), Vmax_bess(k,b), Vmin_bess(k,b), SlackP_bess(k,b));
    end
end

%% === Save ===
save('bess_results.mat', 'der_levels', 'BESS_ratings', 'rating_labels', ...
    'Vmax_bess', 'Vmin_bess', 'SlackP_bess', 'V_limit');
fprintf('\nSaved to bess_results.mat\n');

%% === Summary table ===
fprintf('\n=== HOSTING CAPACITY WITH BESS AT BUS 634 ===\n');
fprintf('%-22s | %-12s | %-14s | %s\n', 'BESS', 'HostCap(kW)', 'Vmin @ 0 kW', 'Status');
fprintf('%s\n', repmat('-', 1, 68));
for b = 1:n_b
    idx = find(Vmax_bess(:, b) > V_limit, 1, 'first');
    if isempty(idx)
        hc = sprintf('> %d', der_levels(end));
    elseif idx == 1
        hc = '0';
    else
        hc = num2str(der_levels(idx-1));
    end
    vmin0 = Vmin_bess(1, b);
    if vmin0 < V_lower, status = 'Vmin violation'; else, status = 'OK'; end
    fprintf('%-22s | %-12s | %.4f         | %s\n', ...
        rating_labels{b}, hc, vmin0, status);
end

%% === Load DSTATCOM data for comparison ===
if exist('dstatcom_ratings.mat', 'file')
    S = load('dstatcom_ratings.mat');
    has_dstat = true;
else
    has_dstat = false;
    fprintf('WARNING: dstatcom_ratings.mat not found — plots will not include DSTATCOM\n');
end

%% === Plot 1: V_max — DSTATCOM vs BESS ===
figure('Position', [100 100 1000 600]);
hold on;

if has_dstat
    plot(S.der_levels, S.Vmax_all(:,1), '-o', 'Color', [0.8 0.2 0.2], ...
        'LineWidth', 2.0, 'MarkerSize', 8, ...
        'DisplayName', 'DSTATCOM 500 kvar');
end

colors = lines(n_b);
markers = {'s', '^', 'd'};
for b = 1:n_b
    plot(der_levels, Vmax_bess(:, b), ['-' markers{b}], ...
        'Color', colors(b,:), 'LineWidth', 1.8, 'MarkerSize', 8, ...
        'MarkerFaceColor', 'none', ...
        'DisplayName', rating_labels{b});
end

yline(V_limit, 'k--', 'LineWidth', 1.8, 'DisplayName', 'V_{max} limit 1.07');
xlabel('DER Injection at Bus 634 (kW)', 'FontSize', 12);
ylabel('V_{max} (p.u.)', 'FontSize', 12);
title('DSTATCOM vs BESS — V_{max} at Bus 634', 'FontSize', 13);
legend('Location', 'best', 'Interpreter', 'none');
grid on;
saveas(gcf, 'BESS_vs_DSTATCOM_Vmax.png');
fprintf('\nPlot saved: BESS_vs_DSTATCOM_Vmax.png\n');

%% === Plot 2: V_min — DSTATCOM vs BESS ===
figure('Position', [100 100 1000 600]);
hold on;

if has_dstat
    plot(S.der_levels, S.Vmin_all(:,1), '-o', 'Color', [0.8 0.2 0.2], ...
        'LineWidth', 2.0, 'MarkerSize', 8, ...
        'DisplayName', 'DSTATCOM 500 kvar');
end

for b = 1:n_b
    plot(der_levels, Vmin_bess(:, b), ['-' markers{b}], ...
        'Color', colors(b,:), 'LineWidth', 1.8, 'MarkerSize', 8, ...
        'MarkerFaceColor', 'none', ...
        'DisplayName', rating_labels{b});
end

yline(V_lower, 'k--', 'LineWidth', 1.8, 'DisplayName', 'V_{min} limit 0.95');
xlabel('DER Injection at Bus 634 (kW)', 'FontSize', 12);
ylabel('V_{min} (p.u.)', 'FontSize', 12);
title('DSTATCOM vs BESS — V_{min}', 'FontSize', 13);
legend('Location', 'best', 'Interpreter', 'none');
grid on;
saveas(gcf, 'BESS_vs_DSTATCOM_Vmin.png');
fprintf('Plot saved: BESS_vs_DSTATCOM_Vmin.png\n');

%% === Final Comparison Table ===
fprintf('\n================ MITIGATION COMPARISON ================\n');
fprintf('%-25s | %-12s | %-12s\n', 'Device', 'HostCap(kW)', 'Vmin @ 0 kW');
fprintf('%s\n', repmat('-', 1, 55));
fprintf('%-25s | %-12s | %.4f\n', 'No mitigation', '2000', 0.9737);

if has_dstat
    idx = find(S.Vmax_all(:,1) > V_limit, 1, 'first');
    if isempty(idx), hc_dst = S.der_levels(end); else, hc_dst = S.der_levels(idx-1); end
    fprintf('%-25s | %-12d | %.4f\n', 'DSTATCOM 500 kvar', hc_dst, S.Vmin_all(1,1));
end

for b = 1:n_b
    idx = find(Vmax_bess(:, b) > V_limit, 1, 'first');
    if isempty(idx)
        hc = der_levels(end);
    elseif idx == 1
        hc = 0;
    else
        hc = der_levels(idx-1);
    end
    fprintf('%-25s | %-12d | %.4f\n', rating_labels{b}, hc, Vmin_bess(1, b));
end