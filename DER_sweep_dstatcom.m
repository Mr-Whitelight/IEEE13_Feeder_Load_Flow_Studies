%% Mitigation Sweep — DSTATCOM rating trade-off analysis
% Tests DSTATCOM at 500, 1000, and 1500 kvar
% Compares hosting capacity and V_min

%% === Clean up ===
clc;
clear;
close all;

% === Configuration ===
model      = 'IEEE13NodeTestFeeder';
V_limit    = 1.07;
V_lower    = 0.95;
der_levels = [0, 500, 1000, 1500, 2000, 2500, 3000, 3500, 4000];   % kW
Q_ratings  = [500e3, 1000e3, 1500e3];   % 500, 1000, 1500 kvar

% === Reload workspace ===
fprintf('Loading init script...\n');
run('IEEE13NodeTestFeederInit');
load_system(model);

%% === AUTO-DETECT pqload cells ===
LF_probe = power_loadflow(model, 'parameters');
cell_634 = []; cell_mit = [];
for c = 1:length(LF_probe.pqload(1).busNumber)
    bn = LF_probe.pqload(1).busNumber{c};
    if all(ismember([9 10 11], bn))
        if isempty(cell_634), cell_634 = c; else cell_mit = c; end
    end
end
fprintf('DER_634 → cell %d | DSTATCOM_634 → cell %d\n', cell_634, cell_mit);

%% === Sweep for each DSTATCOM rating ===
n = length(der_levels);
n_q = length(Q_ratings);

Vmax_all = zeros(n, n_q);
Vmin_all = zeros(n, n_q);

for q = 1:n_q
    Q_mit = Q_ratings(q);
    fprintf('\n=== DSTATCOM = %.0f kvar ===\n', Q_mit/1e3);
    
    for k = 1:n
        LF = power_loadflow(model, 'parameters');
        
        for c = 1:length(LF.pqload(1).P)
            LF.pqload(1).P{c} = 0;
            LF.pqload(1).Q{c} = 0;
        end
        
        LF.pqload(1).P{cell_634} = -der_levels(k) * 1000;
        LF.pqload(1).Q{cell_634} = 0;
        LF.pqload(1).P{cell_mit}  = 0;
        LF.pqload(1).Q{cell_mit}  = Q_mit;
        
        try
            LF_sol = power_loadflow(model, 'solve', LF);
        catch
            continue;
        end
        
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
        
        Vmax_all(k, q) = max(Vmag);
        Vmin_all(k, q) = min(Vmag);
        
        fprintf('  DER=%4d kW | Vmax=%.4f | Vmin=%.4f\n', ...
            der_levels(k), Vmax_all(k,q), Vmin_all(k,q));
    end
end

%% === Save ===
save('dstatcom_ratings.mat', 'der_levels', 'Q_ratings', 'Vmax_all', 'Vmin_all', 'V_limit');
fprintf('\nSaved to dstatcom_ratings.mat\n');

%% === Hosting capacity at each rating ===
fprintf('\n=== HOSTING CAPACITY AT EACH DSTATCOM RATING ===\n');
fprintf('%-15s | %-12s | %-12s\n', 'DSTATCOM', 'HostCap(kW)', 'Vmin at 0 kW');
fprintf('%s\n', repmat('-', 1, 50));
for q = 1:n_q
    idx = find(Vmax_all(:, q) > V_limit, 1, 'first');
    if isempty(idx)
        hc = sprintf('> %d', der_levels(end));
    elseif idx == 1
        hc = '0';
    else
        hc = num2str(der_levels(idx-1));
    end
    fprintf('%-15s | %-12s | %.4f\n', ...
        sprintf('%.0f kvar', Q_ratings(q)/1e3), hc, Vmin_all(1, q));
end

%% === Plot — V_max for each rating ===
figure('Position', [100 100 1000 600]);
hold on;
colors = lines(n_q);
for q = 1:n_q
    plot(der_levels, Vmax_all(:, q), '-o', 'Color', colors(q,:), ...
        'LineWidth', 1.8, ...
        'DisplayName', sprintf('DSTATCOM %.0f kvar', Q_ratings(q)/1e3));
end
yline(V_limit, 'r--', 'LineWidth', 1.8, 'DisplayName', 'V_{max} limit');
xlabel('DER Injection at Bus 634 (kW)', 'FontSize', 12);
ylabel('V_{max} (p.u.)', 'FontSize', 12);
title('Effect of DSTATCOM Rating on V_{max}', 'FontSize', 13);
legend('Location', 'best', 'Interpreter', 'none');
grid on;
saveas(gcf, 'DSTATCOM_ratings_Vmax.png');

%% === Plot — V_min for each rating ===
figure('Position', [100 100 1000 600]);
hold on;
for q = 1:n_q
    plot(der_levels, Vmin_all(:, q), '-s', 'Color', colors(q,:), ...
        'LineWidth', 1.8, ...
        'DisplayName', sprintf('DSTATCOM %.0f kvar', Q_ratings(q)/1e3));
end
yline(V_lower, 'r--', 'LineWidth', 1.8, 'DisplayName', 'V_{min} limit 0.95');
xlabel('DER Injection at Bus 634 (kW)', 'FontSize', 12);
ylabel('V_{min} (p.u.)', 'FontSize', 12);
title('Effect of DSTATCOM Rating on V_{min}', 'FontSize', 13);
legend('Location', 'best', 'Interpreter', 'none');
grid on;
saveas(gcf, 'DSTATCOM_ratings_Vmin.png');