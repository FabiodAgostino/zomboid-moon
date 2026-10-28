using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Input;

namespace Moon.ViewModels;

public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name!);
        return true;
    }

    protected void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// <summary>A command that runs an action, async or not; WPF asks again whether it can run when the UI changes.</summary>
public sealed class Command(Func<object?, Task> run, Func<object?, bool>? canRun = null) : ICommand
{
    public Command(Action run, Func<bool>? canRun = null)
        : this(_ => { run(); return Task.CompletedTask; }, canRun is null ? null : _ => canRun()) { }

    public Command(Func<Task> run, Func<bool>? canRun = null)
        : this(_ => run(), canRun is null ? null : _ => canRun()) { }

    public event EventHandler? CanExecuteChanged
    {
        add => CommandManager.RequerySuggested += value;
        remove => CommandManager.RequerySuggested -= value;
    }

    public bool CanExecute(object? parameter) => canRun?.Invoke(parameter) ?? true;

    public async void Execute(object? parameter) => await run(parameter);
}
