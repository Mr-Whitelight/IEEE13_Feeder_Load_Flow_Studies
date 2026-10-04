%% Locational Hosting Capacity Sweep — 4 Three-Phase Buses
% DER_632 removed (substation bus — swing bus, not valid for DER testing)
% Voltage limit: 1.07 p.u.
% Uses parameters-structure workflow (NO -v2, NO set_param caching)
% Save as DER_sweep.m and run with F5

%% === Clean up ===
clc;
clear;
close all;

% === Configuration ===
model      = 'IEEE13NodeTestFeeder';
V_limit    = 1.07;
der_levels = [0, 500, 1000, 1500, 2000, 2500, 3000, 3500, 4000];   % kW

% DER bus → Simscape node numbers (from pqload.busNumber)
der_buses = {
%   block name    simscape nodes
    'DER_634',    [9 10 11];
    'DER_671',    [16 17 18];
    'DER_675',    [22 23 24];
    'DER_692',    [19 20 21];
};

% === Reload workspace AFTER clear ===
fprintf('Loading init script...\n');
run('IEEE13NodeTestFeederInit');
load_system(model);

%% === AUTO-DETECT pqload cell indices ===
LF_probe = power_loadflow(model, 'parameters');
fprintf('Detected pqload cells: %d\n', length(LF_probe.pqload(1).P));
for c = 1:length(LF_probe.pqload(1).P)
    fprintf('  Cell %d: nodes=%s\n', c, mat2str(LF_probe.pqload(1).busNumber{c}));
end

cell_map = zeros(size(der_buses, 1), 1);
for b = 1:size(der_buses, 1)
    target = der_buses{b, 2};
    found = false;
    for c = 1:length(LF_probe.pqload(1).busNumber)
        bn = LF_probe.pqload(1).busNumber{c};
        if all(ismember(target, bn))
            cell_map(b) = c;
            found = true;
            break;
        end
    end
    if ~found
        error('Could not find pqload cell for %s (nodes %s)', ...
            der_buses{b, 1}, mat2str(target));
    end
    fprintf('Matched %s → pqload cell %d\n', der_buses{b, 1}, cell_map(b));
end

%% === Sweep ===
n = length(der_levels);
results = struct();

for b = 1:size(der_buses, 1)
    blk_name = der_buses{b, 1};
    cell_idx = cell_map(b);
    
    Vmax   = zeros(n,1);
    Vmin   = zeros(n,1);
    SlackP = zeros(n,1);
    
    fprintf('\n=== %s (cell %d) ===\n', blk_name, cell_idx);
    
    for k = 1:n
        % Get fresh parameters
        LF = power_loadflow(model, 'parameters');
        
        % Zero all cells
        for c = 1:length(LF.pqload(1).P)
            LF.pqload(1).P{c} = 0;
            LF.pqload(1).Q{c} = 0;
        end
        
        % Set the active DER cell (negative = injection)
        LF.pqload(1).P{cell_idx} = -der_levels(k) * 1000;
        LF.pqload(1).Q{cell_idx} = 0;
        
        % Solve WITHOUT -v2
        try
            LF_sol = power_loadflow(model, 'solve', LF);
        catch ME
            fprintf('  ERROR at %d kW: %s\n', der_levels(k), ME.message);
            continue;
        end
        
        % --- Extract all bus voltages ---
        Vmag = [];
        
        % Swing bus
        for i = 1:length(LF_sol.vsrc)
            if ~isempty(LF_sol.vsrc(i).Vt)
                Vmag = [Vmag; abs(LF_sol.vsrc(i).Vt{1}(:))];
            end
        end
        
        % RLC loads
        for i = 1:length(LF_sol.rlcload(1).Vt)
            V = abs(LF_sol.rlcload(1).Vt{i}(:));
            V = V(abs(V - 1) > 1e-4);
            Vmag = [Vmag; V];
        end
        
        % PQ loads (Dynamic Loads)
        for i = 1:length(LF_sol.pqload(1).Vt)
            V = abs(LF_sol.pqload(1).Vt{i}(:));
            V = V(abs(V - 1) > 1e-4);
            Vmag = [Vmag; V];
        end
        
        Vmax(k)   = max(Vmag);
        Vmin(k)   = min(Vmag);
        SlackP(k) = sum(real(LF_sol.vsrc(1).S{1})) * LF_sol.basePower / 1e3;
        
        fprintf('  DER=%4d kW | Vmax=%.4f | Vmin=%.4f | SlackP=%.1f kW\n', ...
            der_levels(k), Vmax(k), Vmin(k), SlackP(k));
    end
    
    results.(blk_name).der_levels = der_levels;
    results.(blk_name).Vmax       = Vmax;
    results.(blk_name).Vmin       = Vmin;
    results.(blk_name).SlackP     = SlackP;
end

%% === Save ===
save('locational_hosting_capacity.mat', 'results', 'V_limit', 'der_buses');
fprintf('\nSaved to locational_hosting_capacity.mat\n');

%% === Summary table at chosen limit ===
fprintf('\n================ HOSTING CAPACITY SUMMARY ================\n');
fprintf('Voltage limit: %.2f p.u.\n', V_limit);
fprintf('%-10s | %-12s | %s\n', 'Bus', 'HostCap(kW)', 'Limiting factor');
fprintf('%s\n', repmat('-', 1, 62));
for b = 1:size(der_buses, 1)
    blk = der_buses{b, 1};
    r = results.(blk);
    idx = find(r.Vmax > V_limit, 1, 'first');
    if isempty(idx)
        hc = sprintf('> %d', r.der_levels(end));
        factor = 'None within tested range';
    elseif idx == 1
        hc = '0';
        factor = sprintf('Base case Vmax=%.4f > %.2f', r.Vmax(1), V_limit);
    else
        hc = num2str(r.der_levels(idx-1));
        factor = sprintf('Crosses %.2f at %d kW', V_limit, r.der_levels(idx));
    end
    fprintf('%-10s | %-12s | %s\n', blk, hc, factor);
end

%% === Hosting capacity at multiple limits ===
limits = [1.05, 1.06, 1.07];
fprintf('\n========= HOSTING CAPACITY AT MULTIPLE LIMITS =========\n');
fprintf('%-10s', 'Bus');
for i = 1:length(limits)
    fprintf(' | %6.2f p.u.', limits(i));
end
fprintf('\n%s\n', repmat('-', 1, 58));
for b = 1:size(der_buses, 1)
    blk = der_buses{b, 1};
    r = results.(blk);
    fprintf('%-10s', blk);
    for i = 1:length(limits)
        idx = find(r.Vmax > limits(i), 1, 'first');
        if isempty(idx)
            fprintf(' | >%6d', r.der_levels(end));
        elseif idx == 1
            fprintf(' | %6d', 0);
        else
            fprintf(' | %6d', r.der_levels(idx-1));
        end
    end
    fprintf('\n');
end

%% === Reverse flow threshold ===
fprintf('\n========= REVERSE FLOW THRESHOLD (SlackP < 0) =========\n');
for b = 1:size(der_buses, 1)
    blk = der_buses{b, 1};
    r = results.(blk);
    idx = find(r.SlackP < 0, 1, 'first');
    if isempty(idx)
        fprintf('%-10s | No reverse flow up to %d kW\n', blk, r.der_levels(end));
    else
        fprintf('%-10s | Reverse flow begins at %d kW\n', blk, r.der_levels(idx));
    end
end

%% === Plot 1: V_max vs DER ===
figure('Position', [100 100 1000 600]);
hold on;
blks = fieldnames(results);
colors = lines(length(blks));
for i = 1:length(blks)
    r = results.(blks{i});
    plot(r.der_levels, r.Vmax, '-o', 'Color', colors(i,:), ...
        'LineWidth', 1.8, 'DisplayName', blks{i});
end
yline(V_limit, 'r--', sprintf('Limit %.2f p.u.', V_limit), ...
    'LineWidth', 1.8, 'DisplayName', 'V_{max} limit');
yline(0.95, 'b--', 'Lower limit 0.95 p.u.', ...
    'LineWidth', 1.5, 'DisplayName', 'V_{min} limit');
xlabel('DER Injection (kW)', 'FontSize', 12);
ylabel('V_{max} (p.u.)', 'FontSize', 12);
title(sprintf('Locational Hosting Capacity — IEEE 13-Node (limit %.2f p.u.)', V_limit), ...
    'FontSize', 13);
legend('Location', 'best', 'Interpreter', 'none');
grid on;
saveas(gcf, 'LocationalHostingCapacity.png');
fprintf('\nPlot saved: LocationalHostingCapacity.png\n');

%% === Plot 2: Slack P vs DER ===
figure('Position', [100 100 1000 600]);
hold on;
for i = 1:length(blks)
    r = results.(blks{i});
    plot(r.der_levels, r.SlackP, '-s', 'Color', colors(i,:), ...
        'LineWidth', 1.8, 'DisplayName', blks{i});
end
yline(0, 'k--', 'LineWidth', 1.5, ...
    'DisplayName', 'Reverse flow threshold');
xlabel('DER Injection (kW)', 'FontSize', 12);
ylabel('Slack bus P (kW)', 'FontSize', 12);
title('Substation Power vs DER Injection', 'FontSize', 13);
legend('Location', 'best', 'Interpreter', 'none');
grid on;
saveas(gcf, 'SlackP_vs_DER.png');
fprintf('Plot saved: SlackP_vs_DER.png\n');