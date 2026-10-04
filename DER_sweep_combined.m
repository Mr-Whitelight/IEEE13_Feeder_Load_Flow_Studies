%% Combined Multi-Bus DER Sweep — Simultaneous Injection Scenarios
% Tests aggregate hosting capacity under three distribution strategies:
%   1. Uniform  — equal DER at each bus (25% each)
%   2. Weighted — DER distributed proportionally to local load
%   3. Worst    — all DER at bus 634 (the critical bus)
%
% Uses parameters-structure workflow (NO -v2, NO set_param caching)

%% === Clean up ===
clc;
clear;
close all;

% === Configuration ===
model        = 'IEEE13NodeTestFeeder';
V_limit      = 1.07;
total_levels = [0, 1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000];  % total kW

% DER bus → Simscape node numbers
der_buses = {
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
cell_map = zeros(size(der_buses, 1), 1);
for b = 1:size(der_buses, 1)
    target = der_buses{b, 2};
    for c = 1:length(LF_probe.pqload(1).busNumber)
        bn = LF_probe.pqload(1).busNumber{c};
        if all(ismember(target, bn))
            cell_map(b) = c;
            break;
        end
    end
end
fprintf('Cell map: %s\n', mat2str(cell_map));

%% === Define distribution scenarios ===
% Weights must sum to 1. Order matches der_buses: [634, 671, 675, 692]
scenarios = {
    'Uniform',   [0.25, 0.25, 0.25, 0.25];
    'Weighted',  [0.15, 0.45, 0.30, 0.10];
    'Worst634',  [1.00, 0.00, 0.00, 0.00];
};

n_tot = length(total_levels);
results_combined = struct();

%% === Sweep each scenario ===
for s = 1:size(scenarios, 1)
    scen_name = scenarios{s, 1};
    weights   = scenarios{s, 2};
    
    Vmax   = zeros(n_tot,1);
    Vmin   = zeros(n_tot,1);
    SlackP = zeros(n_tot,1);
    
    fprintf('\n=== Scenario: %s ===\n', scen_name);
    fprintf('  Weights (634/671/675/692): %.2f / %.2f / %.2f / %.2f\n', ...
        weights(1), weights(2), weights(3), weights(4));
    
    for k = 1:n_tot
        LF = power_loadflow(model, 'parameters');
        
        % Zero all cells
        for c = 1:length(LF.pqload(1).P)
            LF.pqload(1).P{c} = 0;
            LF.pqload(1).Q{c} = 0;
        end
        
        % Distribute total DER according to weights (negative = injection)
        for b = 1:length(weights)
            if weights(b) > 0
                LF.pqload(1).P{cell_map(b)} = -weights(b) * total_levels(k) * 1000;
                LF.pqload(1).Q{cell_map(b)} = 0;
            end
        end
        
        try
            LF_sol = power_loadflow(model, 'solve', LF);
        catch ME
            fprintf('  ERROR at %d kW: %s\n', total_levels(k), ME.message);
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
            V = V(abs(V - 1) > 1e-4);
            Vmag = [Vmag; V];
        end
        for i = 1:length(LF_sol.pqload(1).Vt)
            V = abs(LF_sol.pqload(1).Vt{i}(:));
            V = V(abs(V - 1) > 1e-4);
            Vmag = [Vmag; V];
        end
        
        Vmax(k)   = max(Vmag);
        Vmin(k)   = min(Vmag);
        SlackP(k) = sum(real(LF_sol.vsrc(1).S{1})) * LF_sol.basePower / 1e3;
        
        fprintf('  Total=%5d kW | Vmax=%.4f | Vmin=%.4f | SlackP=%.1f kW\n', ...
            total_levels(k), Vmax(k), Vmin(k), SlackP(k));
    end
    
    results_combined.(scen_name).total_levels = total_levels;
    results_combined.(scen_name).weights      = weights;
    results_combined.(scen_name).Vmax         = Vmax;
    results_combined.(scen_name).Vmin         = Vmin;
    results_combined.(scen_name).SlackP       = SlackP;
end

%% === Save ===
save('combined_hosting_capacity.mat', 'results_combined', 'V_limit', 'total_levels');
fprintf('\nSaved to combined_hosting_capacity.mat\n');

%% === Summary table ===
fprintf('\n========= COMBINED HOSTING CAPACITY (limit %.2f p.u.) =========\n', V_limit);
fprintf('%-12s | %-12s | %s\n', 'Scenario', 'HostCap(kW)', 'Limiting factor');
fprintf('%s\n', repmat('-', 1, 62));
scen_names = fieldnames(results_combined);
for s = 1:length(scen_names)
    r = results_combined.(scen_names{s});
    idx = find(r.Vmax > V_limit, 1, 'first');
    if isempty(idx)
        hc = sprintf('> %d', r.total_levels(end));
        factor = 'None within tested range';
    elseif idx == 1
        hc = '0';
        factor = 'Base case already > limit';
    else
        hc = num2str(r.total_levels(idx-1));
        factor = sprintf('Crosses %.2f at %d kW', V_limit, r.total_levels(idx));
    end
    fprintf('%-12s | %-12s | %s\n', scen_names{s}, hc, factor);
end

%% === Comparison with single-bus results ===
fprintf('\n=== COMPARISON: Individual vs Combined ===\n');
fprintf('Single-bus hosting capacities at %.2f p.u.:\n', V_limit);
fprintf('  DER_634: 2000 kW\n');
fprintf('  DER_671: >4000 kW\n');
fprintf('  DER_675: 3000 kW\n');
fprintf('  DER_692: >4000 kW\n');
fprintf('  Sum of best individual: > 13000 kW\n\n');
fprintf('Combined hosting capacities (from this script):\n');
for s = 1:length(scen_names)
    r = results_combined.(scen_names{s});
    idx = find(r.Vmax > V_limit, 1, 'first');
    if isempty(idx)
        hc = r.total_levels(end);
    elseif idx == 1
        hc = 0;
    else
        hc = r.total_levels(idx-1);
    end
    ratio = hc / 13000 * 100;
    fprintf('  %-10s : %5d kW (%.0f%% of single-bus sum)\n', ...
        scen_names{s}, hc, ratio);
end
fprintf('\nThe "diversity penalty" is the ratio between combined and sum.\n');

%% === Plot 1: V_max vs total DER ===
figure('Position', [100 100 1000 600]);
hold on;
scen_names = fieldnames(results_combined);
colors = lines(length(scen_names));
markers = {'o', 's', '^'};
for i = 1:length(scen_names)
    r = results_combined.(scen_names{i});
    plot(r.total_levels, r.Vmax, ['-' markers{i}], ...
        'Color', colors(i,:), 'LineWidth', 1.8, ...
        'MarkerSize', 8, 'MarkerFaceColor', 'none', ...
        'DisplayName', scen_names{i});
end
yline(V_limit, 'r--', 'LineWidth', 1.8, ...
    'DisplayName', sprintf('Limit %.2f p.u.', V_limit));
xlabel('Total DER Injection (kW)', 'FontSize', 12);
ylabel('V_{max} (p.u.)', 'FontSize', 12);
title('Combined DER Injection — Multi-Bus Scenarios', 'FontSize', 13);
legend('Location', 'best', 'Interpreter', 'none');
grid on;
saveas(gcf, 'CombinedHostingCapacity.png');
fprintf('\nPlot saved: CombinedHostingCapacity.png\n');

%% === Plot 2: Slack P vs total DER ===
figure('Position', [100 100 1000 600]);
hold on;
for i = 1:length(scen_names)
    r = results_combined.(scen_names{i});
    plot(r.total_levels, r.SlackP, ['-' markers{i}], ...
        'Color', colors(i,:), 'LineWidth', 1.8, ...
        'MarkerSize', 8, 'MarkerFaceColor', 'none', ...
        'DisplayName', scen_names{i});
end
yline(0, 'k--', 'LineWidth', 1.5, 'DisplayName', 'Reverse flow threshold');
xlabel('Total DER Injection (kW)', 'FontSize', 12);
ylabel('Slack bus P (kW)', 'FontSize', 12);
title('Substation Power vs Total DER Injection', 'FontSize', 13);
legend('Location', 'best', 'Interpreter', 'none');
grid on;
saveas(gcf, 'CombinedSlackP.png');
fprintf('Plot saved: CombinedSlackP.png\n');