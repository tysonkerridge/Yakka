//
//  MultiTask.swift
//  Yakka
//
//  Created by Kieran Harper on 27/12/16.
//
//

import Foundation
import Dispatch

/// Base class for tasks that manage the execution of a collection of tasks. Recommend using ParallelTask or SerialTask, which subclass this.
open class MultiTask: Task {
    
    
    // MARK: - Properties
    
    /// Whether or not all the subtasks need to finish successfully in order to continue and finish with success overall.
    public var requireSuccessFromSubtasks = false
    
    
    
    
    // MARK: - Private variables
    
    /// Set of tasks we've been given
    //NOTE: This is fileprivate so that a custom operator can tap into it
    fileprivate var _allTasks = Array<Task>()
    
    /// Set of tasks that have yet to be asked to run
    private var _pendingTasks = Array<Task>()
    
    /// Set of tasks that have been asked to run
    private var _runningTasks = Array<Task>()
    
    /// Set of tasks that have finished running
    private var _finishedTasks = Array<Task>()
        
    /// The maximum number of tasks we're going to ask to start before waiting for some to finish. Defaults to unlimited (0)
    fileprivate var _maxParallelTasks = 0
    
    /// The Process object for the overall task (this one)
    private var _overallProcess: Process?
    
    /// Tracking of the percent completion of each of the subtasks, in order to provide overall progress feedback
    private var _taskProgressions = Dictionary<String, Float>()
    
    
    
    
    // MARK: - Lifecycle
    
    /// Construct with the set of tasks to run together
    public init(involving tasks: [Task]) {
        super.init()
        _allTasks = tasks
        workToDo { [weak self] (process) in
            guard let selfRef = self else { return }
            
            // Start executing tasks
            selfRef._overallProcess = process
            selfRef._pendingTasks = tasks
            selfRef.helperGetStarted()
        }
    }
    
    private func helperGetStarted() {
        _overallProcess?.onShouldCancel { [weak self] in
            self?._internalQueue.async {
                self?.handleCancelling()
            }
        }
        _internalQueue.async {
            self.processSubtasks()
        }
    }
    
    
    
    
    // MARK: - Private (ON INTERNAL)
    
    /// Start tasks as needed, consider cancellation etc
    private func processSubtasks() {
        
        // Check for cancellation by passing it on to subtasks and prevent pending ones from starting
        if _currentState == .cancelling {
            handleCancelling()
        }
        
        // Start any tasks we can and/or have remaining
        while (_runningTasks.count < _maxParallelTasks || _maxParallelTasks == 0), let next = _pendingTasks.first {
            startSubtask(next)
        }
        
        // Finish up if there's nothing left we're waiting on
        if _pendingTasks.count == 0, _runningTasks.count == 0 {
            
            // Consider whether or not we're here because all our tasks were actually cancelling
            if _currentState == .cancelling {
                _overallProcess?.cancel()
            } else {
                _overallProcess?.succeed()
            }
            _overallProcess = nil
        }
    }
    
    /// Start a specific sub task, setting up progress reporting and completion etc
    private func startSubtask(_ task: Task) {
        
        // Move from pending into running
        move(subtask: task, fromCollection: &_pendingTasks, toCollection: &_runningTasks)
        
        // Handle progress, by accumulating the percentages of all tasks (they're equally weighted)
        // NOTE: Careful not to retain self OR the task here
        let taskID = task.identifier
        task.onProgress(via: _internalQueue) { [weak self] (percent) in
            self?.helperReportProgress(percent, forTaskID: taskID)
        }
        
        // Schedule completion
        // NOTE: Careful not to retain self OR the task here
        task.onFinish(via: _internalQueue) { [weak self, weak task] (outcome) in
            guard let selfRef = self, let taskRef = task else { return }
            selfRef.subtaskFinished(taskRef, withOutcome: outcome)
        }
        
        // Kick it off
        // NOTE: If already running or finished, this will do nothing but onFinish will run
        task.start(using: self._queueForWork)
    }
    
    /// Handle a subtask finishing, consider what to do next
    private func subtaskFinished(_ task: Task, withOutcome outcome: Outcome) {
        
        // Ensure we report a minimum level of progress
        if outcome == .success {
            helperReportProgress(1.0, forTaskID: task.identifier)
        }
        
        // Put it in the finished pile
        move(subtask: task, fromCollection: &_runningTasks, toCollection: &_finishedTasks)
        
        // If we're supposed to fail whenever an outcome isn't successful, then handle that now
        if requireSuccessFromSubtasks, outcome != .success {
            for running in _runningTasks {
                running.cancel()
            }
            _overallProcess?.fail()
            return
        }
        
        // Otherwise consider starting any subsequent task/s
        processSubtasks()
    }
    
    /// Handle the intention to cancel by telling everything to cancel and removing tasks that haven't run yet
    private func handleCancelling() {
        for task in _allTasks {
            task.cancel()
        }
        _pendingTasks.removeAll()
    }
    
    /// Report progress for a subtask
    private func helperReportProgress(_ progress: Float, forTaskID taskID: String) {
        _taskProgressions[taskID] = progress
        let overallPercent = _taskProgressions.reduce(0.0, { $0 + $1.value }) / Float(_allTasks.count)
        _overallProcess?.progress(overallPercent)
    }
}




/// Task that serializes subtask execution so that each task waits for completion of the one before it
open class SerialTask: MultiTask {
    
    /// Construct with the set of tasks to run in order
    public override init(involving tasks: [Task]) {
        super.init(involving: tasks)
        _maxParallelTasks = 1
    }
}




/// Task that allows multiple subtasks to run concurrently with one another
open class ParallelTask: MultiTask {
    
    /// Optional limit on the number of subtasks that can run concurrently. Defaults to unlimited (0)
    public final var maxConcurrentTasks: Int {
        get {
            return _maxParallelTasks
        }
        set {
            _maxParallelTasks = newValue
        }
    }
}




/// Operators to construct multi-tasks with ease
infix operator --> : AdditionPrecedence
infix operator ||| : AdditionPrecedence
extension Task {
    
    /// String a series of tasks together into a SerialTask
    public static func --> (left: Task, right: Task) -> SerialTask {
        var tasks = [Task]()
        
        // Handle the expectation that this is going to be used in a chain and that the item on the left may be the result of a previous operation.
        if let leftSerial = left as? SerialTask {
            tasks.append(contentsOf: leftSerial._allTasks)
        } else {
            tasks.append(left)
        }
        
        // Just add the one on the right as-is
        tasks.append(right)
        
        // Create a new serial task ready for execution
        return SerialTask(involving: tasks)
    }
    
    /// String a series of tasks together into a ParallelTask
    public static func ||| (left: Task, right: Task) -> ParallelTask {
        var tasks = [Task]()
        
        // Handle the expectation that this is going to be used in a chain and that the item on the left may be the result of a previous operation.
        if let leftParallel = left as? ParallelTask {
            tasks.append(contentsOf: leftParallel._allTasks)
        } else {
            tasks.append(left)
        }
        
        // Just add the one on the right as-is
        tasks.append(right)
        
        return ParallelTask(involving: tasks)
    }
}




// MARK: - General purpose helpers

internal func remove(subtask: Task, fromCollection: inout Array<Task>) {
    if let index = indexOf(subtask: subtask, inCollection: fromCollection) {
        fromCollection.remove(at: index)
    }
}

/// Helper to shift subtasks between sets for tracking
internal func move(subtask: Task, fromCollection: inout Array<Task>, toCollection: inout Array<Task>) {
    remove(subtask: subtask, fromCollection: &fromCollection)
    toCollection.append(subtask)
}

/// Helper to find a task in a collection
internal func indexOf(subtask: Task, inCollection collection: Array<Task>) -> Int? {
    return collection.index { (t) -> Bool in
        return t == subtask
    }
}

